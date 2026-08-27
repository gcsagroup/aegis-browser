// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_ai_control.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_
#define CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_

#include <string>
#include <string_view>

namespace aegis {

// 只接受带非零端口的数值 loopback 地址。拒绝 localhost 等需 DNS
// 解析的主机名，避免状态判断与实际绑定结果不一致。
bool IsLoopbackDevToolsAddress(std::string_view address, int* port);

// Aegis 的本机自动化不依赖浏览器 Origin 白名单。只要进程显式配置了
// --remote-allow-origins，就拒绝启用，避免复用被扩大授权的 CDP 服务。
bool HasExplicitRemoteAllowOrigins(std::string_view origins);

// 本机 CDP / DevTools，默认关闭。开启后只绑定 127.0.0.1 / ::1，不绑 0.0.0.0。
class AiControl {
 public:
  static constexpr int kDefaultPort = 9222;

  AiControl();
  AiControl(const AiControl&) = delete;
  AiControl& operator=(const AiControl&) = delete;
  ~AiControl();

  bool Start();
  void Stop();

  bool running() const;
  bool loopback_only() const;
  bool started_by_us() const { return started_by_us_; }
  int port() const;
  std::string address() const;

 private:
  // 表示本实例已接受现有安全服务或已发起安全服务启动。公开状态始终
  // 重新读取 Chromium 的真实监听地址，不把启动请求当作运行成功。
  bool active_ = false;
  bool started_by_us_ = false;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_
