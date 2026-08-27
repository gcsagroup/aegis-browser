// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_ai_control.cc

#include "chrome/browser/aegis/aegis_ai_control.h"

#include <memory>
#include <string>
#include <utility>

#include "base/command_line.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/strings/string_split.h"
#include "chrome/common/chrome_paths.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_socket_factory.h"
#include "content/public/common/content_switches.h"
#include "net/base/host_port_pair.h"
#include "net/base/ip_address.h"
#include "net/base/net_errors.h"
#include "net/log/net_log_source.h"
#include "net/socket/tcp_server_socket.h"

namespace aegis {
namespace {

constexpr int kBackLog = 10;

class LoopbackDevToolsSocketFactory : public content::DevToolsSocketFactory {
 public:
  explicit LoopbackDevToolsSocketFactory(uint16_t port) : port_(port) {}
  LoopbackDevToolsSocketFactory(const LoopbackDevToolsSocketFactory&) = delete;
  LoopbackDevToolsSocketFactory& operator=(
      const LoopbackDevToolsSocketFactory&) = delete;
  ~LoopbackDevToolsSocketFactory() override = default;

  std::unique_ptr<net::ServerSocket> CreateForHttpServer() override {
    std::unique_ptr<net::ServerSocket> socket = Listen("127.0.0.1", port_);
    if (socket) {
      return socket;
    }
    if (port_ != 0) {
      socket = Listen("127.0.0.1", 0);
      if (socket) {
        return socket;
      }
    }
    socket = Listen("::1", port_);
    if (socket) {
      return socket;
    }
    if (port_ != 0) {
      return Listen("::1", 0);
    }
    return nullptr;
  }

  std::unique_ptr<net::ServerSocket> CreateForTethering(
      std::string* /*out_name*/) override {
    return nullptr;
  }

 private:
  std::unique_ptr<net::ServerSocket> Listen(const char* address,
                                            uint16_t port) {
    auto socket =
        std::make_unique<net::TCPServerSocket>(nullptr, net::NetLogSource());
    if (socket->ListenWithAddressAndPort(address, port, kBackLog) == net::OK) {
      return socket;
    }
    return nullptr;
  }

  const uint16_t port_;
};

bool GetActiveLoopbackEndpoint(std::string* address, int* port) {
  std::string current =
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
  if (!IsLoopbackDevToolsAddress(current, port)) {
    return false;
  }
  if (address) {
    *address = std::move(current);
  }
  return true;
}

}  // namespace

bool IsLoopbackDevToolsAddress(std::string_view address, int* port) {
  if (port) {
    *port = 0;
  }
  const net::HostPortPair endpoint = net::HostPortPair::FromString(address);
  if (endpoint.IsEmpty() || endpoint.port() == 0) {
    return false;
  }

  net::IPAddress ip;
  if (!ip.AssignFromIPLiteral(endpoint.host()) || !ip.IsLoopback()) {
    return false;
  }
  if (port) {
    *port = endpoint.port();
  }
  return true;
}

bool HasExplicitRemoteAllowOrigins(std::string_view origins) {
  return !base::SplitStringPiece(origins, ",", base::TRIM_WHITESPACE,
                                 base::SPLIT_WANT_NONEMPTY)
              .empty();
}

AiControl::AiControl() = default;

AiControl::~AiControl() {
  Stop();
}

bool AiControl::Start() {
  if (active_) {
    const std::string current =
        content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
    // 自行启动的服务在异步绑定完成前地址为空；除此之外仍按真实地址
    // 复核，不能因旧的 active_ 状态重复报告成功。
    return (started_by_us_ && current.empty()) ||
           IsLoopbackDevToolsAddress(current, nullptr);
  }

  // 无 Origin 的本机 Playwright WebSocket 可被 Chromium 默认策略接受；
  // 不再为它扩大浏览器 Origin 权限。若进程已显式允许任意 Origin，
  // 即使不是通配符，也拒绝复用这个进程内的调试服务。
  const base::CommandLine* command_line =
      base::CommandLine::ForCurrentProcess();
  if (HasExplicitRemoteAllowOrigins(
          command_line->GetSwitchValueASCII(switches::kRemoteAllowOrigins))) {
    LOG(ERROR) << "Aegis AI control: refusing explicit remote Origins";
    return false;
  }

  const std::string existing =
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
  if (!existing.empty()) {
    int existing_port = 0;
    if (!IsLoopbackDevToolsAddress(existing, &existing_port)) {
      LOG(ERROR) << "Aegis AI control: refusing existing non-loopback or "
                    "invalid CDP endpoint: "
                 << existing;
      return false;
    }
    active_ = true;
    started_by_us_ = false;
    LOG(INFO) << "Aegis AI control: using existing loopback CDP endpoint "
              << existing;
    return true;
  }

  base::FilePath output_dir;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &output_dir)) {
    LOG(ERROR) << "Aegis AI control: user data directory is unavailable";
    return false;
  }

  content::DevToolsAgentHost::StartRemoteDebuggingServer(
      std::make_unique<LoopbackDevToolsSocketFactory>(kDefaultPort), output_dir,
      base::FilePath(),
      content::DevToolsAgentHost::RemoteDebuggingServerMode::kDefault);

  active_ = true;
  started_by_us_ = true;

  // Chromium 异步创建监听 socket。若地址已就绪则立即复核；尚未就绪时，
  // running()/address()/port() 会继续以真实地址为准，绝不伪造成功状态。
  const std::string current =
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
  if (!current.empty() && !IsLoopbackDevToolsAddress(current, nullptr)) {
    LOG(ERROR) << "Aegis AI control: started unsafe CDP endpoint: " << current;
    Stop();
    return false;
  }
  LOG(INFO) << "Aegis AI control: requested loopback-only CDP endpoint";
  return true;
}

void AiControl::Stop() {
  if (active_ && started_by_us_) {
    content::DevToolsAgentHost::StopRemoteDebuggingServer();
  }
  active_ = false;
  started_by_us_ = false;
}

bool AiControl::running() const {
  return active_ && GetActiveLoopbackEndpoint(nullptr, nullptr);
}

bool AiControl::loopback_only() const {
  return running();
}

int AiControl::port() const {
  int current_port = 0;
  if (!active_ || !GetActiveLoopbackEndpoint(nullptr, &current_port)) {
    return 0;
  }
  return current_port;
}

std::string AiControl::address() const {
  std::string current;
  if (!active_ || !GetActiveLoopbackEndpoint(&current, nullptr)) {
    return std::string();
  }
  return current;
}

}  // namespace aegis
