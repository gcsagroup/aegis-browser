// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_ws_hook.h

#ifndef CHROME_COMMON_AEGIS_CDP_WS_HOOK_H_
#define CHROME_COMMON_AEGIS_CDP_WS_HOOK_H_

#include <cstddef>

#include "base/functional/callback.h"

namespace aegis {

// chrome/common 不能依赖 chrome/browser。DevTools delegate 经此回调
// 把远程 WebSocket 客户端数量交给 AegisService。
class CdpWsHook {
 public:
  using ClientCountCallback = base::RepeatingCallback<void(size_t count)>;

  static void SetClientCountCallback(ClientCountCallback callback);
  static void NotifyClientCount(size_t count);
};

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CDP_WS_HOOK_H_
