// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter.h

#ifndef CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_
#define CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_

#include <string_view>

class GURL;

namespace aegis {

// 仅表示已经解析到 DevToolsAgentHost 的远程 CDP 操作。所有接收 target id
// 或向远程客户端暴露 target 的入口都必须使用同一授权结果，避免只隐藏
// 列表、仍可按 id 附加或关闭内部页面。
enum class RemoteCdpTargetOperation {
  kEnumerate,
  kCreate,
  kWebSocketConnect,
  kGetInfo,
  kAttach,
  kNavigate,
  kActivate,
  kClose,
  kExposeDevToolsProtocol,
  kOpenDevTools,
};

// 远程 CDP target 操作授权。|type| 与
// content::DevToolsAgentHost::kType* 字符串一致（"browser" 等）。既存 target
// 操作传当前 URL；kCreate/kNavigate 必须传请求的目的 URL，不能用当前页面
// URL 代替。
// Target.setDiscoverTargets / Target.setAutoAttach 是无 target 的会话命令，
// 不得用此函数拒绝命令本身；应分别用 kEnumerate / kAttach 过滤命令随后
// 产生的每个 discovered/auto-attach target。本地 F12 不应走该远程入口。
// kCreate 可引导创建 about:blank，但后续操作只允许创建它的同一 root CDP
// 客户端；该所有权由 content handler 校验，不由本纯策略函数推断。
//
// 这是纯策略函数；远程 protocol handler 的生产接线仍需在 Chromium
// checkout 中完成并由集成测试证明。
bool ShouldAllowRemoteCdpTargetOperation(RemoteCdpTargetOperation operation,
                                         std::string_view type,
                                         const GURL& url);

// 兼容 /json/list 等现有枚举调用点；新代码应传入具体操作。
bool ShouldExposeRemoteCdpTarget(std::string_view type, const GURL& url);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_CDP_TARGET_FILTER_H_
