// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_GESTURES_GESTURE_RECOGNIZER_H_
#define CHROME_BROWSER_AEGIS_GESTURES_GESTURE_RECOGNIZER_H_

#include <string>

namespace aegis {

// 坐标统一为 DIP；识别与页面、系统鼠标速度及显示器像素密度无关。
class GestureRecognizer {
 public:
  void Start(float x, float y, int threshold);
  void Move(float x, float y);
  void Cancel();
  bool moved() const { return moved_; }
  bool cancelled() const { return cancelled_; }
  const std::string& directions() const { return directions_; }
  std::string Match() const;

 private:
  float anchor_x_ = 0;
  float anchor_y_ = 0;
  int threshold_ = 16;
  bool moved_ = false;
  bool cancelled_ = false;
  bool ambiguous_ = false;
  std::string directions_;
};

}  // namespace aegis
#endif
