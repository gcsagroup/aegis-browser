// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_GESTURES_GESTURE_SETTINGS_H_
#define CHROME_BROWSER_AEGIS_GESTURES_GESTURE_SETTINGS_H_

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/supports_user_data.h"
#include "base/values.h"

class GURL;

namespace aegis {
inline constexpr char kMouseGesturesPref[] = "aegis.mouse_gestures";
inline constexpr char kGesturePracticeKey[] = "aegis.gesture_practice";

struct GestureAction {
  const char* id;
  const char* label;
  bool pdf_only;
};
const std::vector<GestureAction>& GestureActions();
const GestureAction* FindGestureAction(std::string_view id);
bool IsGesturePattern(std::string_view pattern);

struct GestureSettings {
  bool enabled = true;
  bool show_trail = true;
  int threshold = 16;
  std::map<std::string, std::string> bindings;
  std::vector<std::string> disabled_sites;

  static GestureSettings Defaults();
  // 整份校验后再保存，拒绝未知动作和冲突配置，不做部分写入。
  static std::optional<GestureSettings> Parse(const base::DictValue& value);
  base::DictValue ToValue() const;
  bool EnabledFor(const GURL& url) const;
  std::string ActionFor(std::string_view pattern) const;
};

// 只由内置设置页提供的练习区域，坐标相对于可视内容区归一化。
// 数据属于当前标签，导航时清除，不写入 Profile。
struct GesturePracticeRegion : base::SupportsUserData::Data {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
  bool Contains(double px, double py) const;
};
}  // namespace aegis
#endif
