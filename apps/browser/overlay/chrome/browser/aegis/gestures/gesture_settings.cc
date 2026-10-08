// Copyright 2026 GCSA
#include "chrome/browser/aegis/gestures/gesture_settings.h"

#include <algorithm>
#include <set>

#include "base/no_destructor.h"
#include "url/gurl.h"

namespace aegis {

const std::vector<GestureAction>& GestureActions() {
  static const base::NoDestructor<std::vector<GestureAction>> actions({
      {"back", "后退", false},
      {"forward", "前进", false},
      {"scroll_up", "向上滚动", false},
      {"scroll_down", "向下滚动", false},
      {"reload", "刷新", false},
      {"close_tab", "关闭当前标签", false},
      {"restore_tab", "恢复关闭的标签", false},
      {"previous_tab", "左侧标签", false},
      {"next_tab", "右侧标签", false},
      {"pdf_previous", "PDF 上一页", true},
      {"pdf_next", "PDF 下一页", true},
      {"pdf_width", "PDF 适合宽度", true},
      {"pdf_page", "PDF 适合整页", true},
  });
  return *actions;
}

const GestureAction* FindGestureAction(std::string_view id) {
  for (const auto& action : GestureActions()) {
    if (action.id == id) {
      return &action;
    }
  }
  return nullptr;
}

bool IsGesturePattern(std::string_view pattern) {
  if (pattern.empty() || pattern.size() > 8) {
    return false;
  }
  char previous = 0;
  for (char direction : pattern) {
    if (std::string_view("LRUD").find(direction) == std::string_view::npos ||
        direction == previous) {
      return false;
    }
    previous = direction;
  }
  return true;
}

GestureSettings GestureSettings::Defaults() {
  GestureSettings settings;
  settings.bindings = {
      {"L", "back"},         {"R", "forward"},       {"U", "scroll_up"},
      {"D", "scroll_down"},  {"UD", "reload"},       {"DR", "close_tab"},
      {"DL", "restore_tab"}, {"UL", "previous_tab"}, {"UR", "next_tab"}};
  return settings;
}

std::optional<GestureSettings> GestureSettings::Parse(
    const base::DictValue& value) {
  const auto enabled = value.FindBool("enabled");
  const auto trail = value.FindBool("showTrail");
  const auto threshold = value.FindInt("threshold");
  const auto* bindings = value.FindDict("bindings");
  const auto* sites = value.FindList("disabledSites");
  if (value.size() != 5 || !enabled || !trail || !threshold || *threshold < 8 ||
      *threshold > 64 || !bindings || bindings->size() > 64 || !sites ||
      sites->size() > 100) {
    return std::nullopt;
  }
  GestureSettings settings;
  settings.enabled = *enabled;
  settings.show_trail = *trail;
  settings.threshold = *threshold;
  for (const auto [pattern, action] : *bindings) {
    if (!IsGesturePattern(pattern) || !action.is_string() ||
        !FindGestureAction(action.GetString())) {
      return std::nullopt;
    }
    settings.bindings.emplace(pattern, action.GetString());
  }
  std::set<std::string> seen;
  for (const auto& site : *sites) {
    if (!site.is_string() || site.GetString().empty() ||
        site.GetString().size() > 253) {
      return std::nullopt;
    }
    const auto& name = site.GetString();
    const GURL url("https://" + name + "/");
    if (!url.is_valid() || url.host() != name || url.has_port() ||
        url.has_username() || url.has_password() || url.path() != "/" ||
        url.has_query() || url.has_ref() || !seen.insert(name).second) {
      return std::nullopt;
    }
    settings.disabled_sites.push_back(name);
  }
  return settings;
}

base::DictValue GestureSettings::ToValue() const {
  base::DictValue mapping;
  for (const auto& [pattern, action] : bindings) {
    mapping.Set(pattern, action);
  }
  base::ListValue sites;
  for (const auto& site : disabled_sites) {
    sites.Append(site);
  }
  return base::DictValue()
      .Set("enabled", enabled)
      .Set("showTrail", show_trail)
      .Set("threshold", threshold)
      .Set("bindings", std::move(mapping))
      .Set("disabledSites", std::move(sites));
}

bool GestureSettings::EnabledFor(const GURL& url) const {
  return enabled &&
         std::ranges::find(disabled_sites, url.host()) == disabled_sites.end();
}

std::string GestureSettings::ActionFor(std::string_view pattern) const {
  const auto found = bindings.find(std::string(pattern));
  return found == bindings.end() ? std::string() : found->second;
}

bool GesturePracticeRegion::Contains(double px, double py) const {
  return width > 0 && height > 0 && px >= x && px <= x + width && py >= y &&
         py <= y + height;
}
}  // namespace aegis
