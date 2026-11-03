// Copyright 2026 The GCSA Aegis Authors
// 安装整体进度的保守预估模型；只负责展示，不判断安装结果或改变安装工作。
#ifndef CHROME_INSTALLER_MINI_INSTALLER_AEGIS_OVERALL_PROGRESS_H_
#define CHROME_INSTALLER_MINI_INSTALLER_AEGIS_OVERALL_PROGRESS_H_

#include "chrome/installer/aegis_install_progress.h"

namespace mini_installer {

// 用实测阶段完成量校准固定权重，无分母时按耗时缓慢接近阶段上限。
// 状态只由 UI 线程持有；时间由调用方传入，使用单调时钟的毫秒值。
class AegisOverallProgress {
 public:
  explicit AegisOverallProgress(ULONGLONG now)
      : phase_started_(now), last_tick_(now) {}

  // 接收阶段观测；忽略无效值、倒退值及回滚后的迟到消息。
  void Update(aegis_installer::Progress progress, ULONGLONG now) {
    using aegis_installer::Phase;
    if (rolling_back_ || progress.percent < -1 || progress.percent > 99 ||
        static_cast<unsigned>(progress.phase) >
            static_cast<unsigned>(Phase::kRollingBack))
      return;
    if (progress.phase == Phase::kRollingBack) {
      rolling_back_ = true;
      return;
    }
    // setup 的短暂辅助步骤可能回报 preparing；不能让整体完成量重置。
    if (progress.phase < phase_)
      return;
    if (progress.phase != phase_) {
      phase_ = progress.phase;
      phase_started_ = now;
      reported_ = -1;
    }
    if (progress.percent > reported_)
      reported_ = progress.percent;
  }

  // 推进显示值并返回是否变化；关闭系统动画时直接显示当前估计值。
  // 即使阶段耗时远超预期也不越过该阶段上限，最终 100% 只能由成功结果显示。
  bool Advance(ULONGLONG now, bool animate = true) {
    if (now < last_tick_)
      return false;
    ULONGLONG delta = now - last_tick_;
    last_tick_ = now;
    if (rolling_back_)
      return false;
    Range range = CurrentRange();
    ULONGLONG elapsed = now >= phase_started_ ? now - phase_started_ : 0;
    if (elapsed > 3600000)
      elapsed = 3600000;
    int fraction =
        reported_ >= 0
            ? reported_ * 100
            : static_cast<int>(elapsed * 10000 / (elapsed + range.expected_ms));
    int estimate = range.begin + (range.end - range.begin) * fraction / 10000;
    if (estimate > 9900)
      estimate = 9900;
    if (estimate > target_)
      target_ = estimate;
    int previous = position_;
    if (!animate) {
      position_ = target_;
    } else if (delta && position_ < target_) {
      // 使用百分之一百分点平滑趋近，不卡在整数跳变；恢复窗口时限制单帧跃迁。
      if (delta > 250)
        delta = 250;
      int step =
          static_cast<int>((target_ - position_) * delta / (180 + delta));
      position_ += step > 0 ? step : 1;
    }
    return position_ != previous;
  }

  // 以百分之一百分点表示，范围为 0..9900；文本百分比向下取整。
  int position() const { return position_; }
  int percent() const { return position_ / 100; }
  bool rolling_back() const { return rolling_back_; }

 private:
  struct Range {
    int begin;
    int end;
    ULONGLONG expected_ms;
  };
  Range CurrentRange() const {
    using aegis_installer::Phase;
    // 解压占主要预算，文件提交次之；配置与收尾保留空间，阶段切换不回到零。
    switch (phase_) {
      case Phase::kDecompressing:
        return {400, 6000, 30000};
      case Phase::kUnpacking:
        return {6000, 7800, 10000};
      case Phase::kInstalling:
        return {7800, 9400, 12000};
      case Phase::kConfiguring:
        return {9400, 9700, 3000};
      case Phase::kFinishing:
        return {9700, 10000, 5000};
      default:
        return {0, 400, 3000};
    }
  }

  aegis_installer::Phase phase_ = aegis_installer::Phase::kPreparing;
  ULONGLONG phase_started_;
  ULONGLONG last_tick_;
  int reported_ = -1;
  int target_ = 0;
  int position_ = 0;
  bool rolling_back_ = false;
};
}  // namespace mini_installer

#endif  // CHROME_INSTALLER_MINI_INSTALLER_AEGIS_OVERALL_PROGRESS_H_
