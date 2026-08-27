// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_ai_control.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_
#define CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_

#include <string>

namespace aegis {

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

  bool running() const { return running_; }
  bool loopback_only() const { return true; }
  bool started_by_us() const { return started_by_us_; }
  int port() const { return port_; }
  std::string address() const { return address_; }

 private:
  bool running_ = false;
  bool started_by_us_ = false;
  int port_ = 0;
  std::string address_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_AI_CONTROL_H_
