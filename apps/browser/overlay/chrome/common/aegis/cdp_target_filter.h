// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter.h

#ifndef CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_
#define CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_

#include <string_view>

class GURL;

namespace aegis {

// 远程 CDP（Playwright /json/list、Target.getTargets）可见的 target。
// 本地 F12 不走这条路径，因此不会挡住检查 chrome://aegis。
// |type| 与 content::DevToolsAgentHost::kType* 字符串一致（"browser" 等）。
bool ShouldExposeRemoteCdpTarget(std::string_view type, const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_
