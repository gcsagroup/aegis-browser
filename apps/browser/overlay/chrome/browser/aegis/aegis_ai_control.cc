// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_ai_control.cc

#include "chrome/browser/aegis/aegis_ai_control.h"

#include <memory>
#include <string>

#include "base/command_line.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "chrome/common/chrome_paths.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_socket_factory.h"
#include "content/public/common/content_switches.h"
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
    std::unique_ptr<net::ServerSocket> socket =
        Listen("127.0.0.1", port_);
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
  std::unique_ptr<net::ServerSocket> Listen(const char* address, uint16_t port) {
    auto socket =
        std::make_unique<net::TCPServerSocket>(nullptr, net::NetLogSource());
    if (socket->ListenWithAddressAndPort(address, port, kBackLog) == net::OK) {
      return socket;
    }
    return nullptr;
  }

  const uint16_t port_;
};

int ParsePortFromAddress(const std::string& address) {
  const size_t colon = address.rfind(':');
  if (colon == std::string::npos) {
    return 0;
  }
  int port = 0;
  if (!base::StringToInt(address.substr(colon + 1), &port) || port < 0 ||
      port > 65535) {
    return 0;
  }
  return port;
}

bool AddressIsLoopback(const std::string& address) {
  return base::StartsWith(address, "127.0.0.1") ||
         base::StartsWith(address, "[::1]") ||
         base::StartsWith(address, "::1") ||
         base::StartsWith(address, "localhost");
}

void AllowLoopbackDevToolsOrigins() {
  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(switches::kRemoteAllowOrigins)) {
    return;
  }
  // 服务只绑 loopback；放开 origin 是为了让本机 Playwright 能连。
  command_line->AppendSwitchASCII(switches::kRemoteAllowOrigins, "*");
}

}  // namespace

AiControl::AiControl() = default;

AiControl::~AiControl() {
  Stop();
}

bool AiControl::Start() {
  const std::string existing =
      content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
  if (!existing.empty()) {
    running_ = true;
    started_by_us_ = false;
    address_ = existing;
    port_ = ParsePortFromAddress(existing);
    if (!AddressIsLoopback(existing)) {
      LOG(WARNING) << "Aegis AI control: existing CDP bind is not loopback: "
                   << existing;
    }
    return true;
  }

  AllowLoopbackDevToolsOrigins();

  base::FilePath output_dir;
  base::PathService::Get(chrome::DIR_USER_DATA, &output_dir);

  content::DevToolsAgentHost::StartRemoteDebuggingServer(
      std::make_unique<LoopbackDevToolsSocketFactory>(kDefaultPort),
      output_dir, base::FilePath(),
      content::DevToolsAgentHost::RemoteDebuggingServerMode::kDefault);

  address_ = content::DevToolsAgentHost::GetRemoteDebuggingServerAddress();
  if (address_.empty()) {
    address_ = "127.0.0.1:" + base::NumberToString(kDefaultPort);
  }
  port_ = ParsePortFromAddress(address_);
  if (port_ == 0) {
    port_ = kDefaultPort;
  }
  running_ = true;
  started_by_us_ = true;
  LOG(INFO) << "Aegis AI control: CDP listening on " << address_
            << " (loopback only)";
  return true;
}

void AiControl::Stop() {
  if (!running_) {
    return;
  }
  if (started_by_us_) {
    content::DevToolsAgentHost::StopRemoteDebuggingServer();
  }
  running_ = false;
  started_by_us_ = false;
  port_ = 0;
  address_.clear();
}

}  // namespace aegis
