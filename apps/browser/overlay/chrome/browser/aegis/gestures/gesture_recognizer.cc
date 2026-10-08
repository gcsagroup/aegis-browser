// Copyright 2026 GCSA
#include "chrome/browser/aegis/gestures/gesture_recognizer.h"

#include <algorithm>
#include <cmath>

namespace aegis {

void GestureRecognizer::Start(float x, float y, int threshold) {
  anchor_x_ = x;
  anchor_y_ = y;
  threshold_ = std::clamp(threshold, 8, 64);
  moved_ = cancelled_ = ambiguous_ = false;
  directions_.clear();
}

void GestureRecognizer::Move(float x, float y) {
  if (cancelled_) {
    return;
  }
  const float dx = x - anchor_x_;
  const float dy = y - anchor_y_;
  if (!std::isfinite(dx) || !std::isfinite(dy)) {
    Cancel();
    return;
  }
  if (std::hypot(dx, dy) < threshold_) {
    return;
  }
  moved_ = true;
  const float ax = std::abs(dx);
  const float ay = std::abs(dy);
  // 对角线不猜方向；最后一段仍然含糊时，整个手势不执行。
  ambiguous_ = std::max(ax, ay) < 1.35f * std::min(ax, ay);
  if (ambiguous_) {
    return;
  }
  const char direction = ax > ay ? (dx > 0 ? 'R' : 'L') : (dy > 0 ? 'D' : 'U');
  if (directions_.empty() || directions_.back() != direction) {
    directions_ += direction;
  }
  anchor_x_ = x;
  anchor_y_ = y;
  if (directions_.size() > 8) {
    Cancel();
  }
}

void GestureRecognizer::Cancel() {
  cancelled_ = true;
}

std::string GestureRecognizer::Match() const {
  return moved_ && !cancelled_ && !ambiguous_ ? directions_ : std::string();
}

}  // namespace aegis
