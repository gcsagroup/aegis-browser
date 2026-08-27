// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_target_filter.cc

#include "chrome/common/aegis/cdp_target_filter.h"

#include "url/gurl.h"
#include "url/origin.h"
#include "url/url_constants.h"

namespace aegis {
namespace {

bool IsRemoteWebTargetType(std::string_view type) {
  return type == "page" || type == "tab" || type == "iframe" ||
         type == "service_worker" || type == "shared_worker" ||
         type == "worker";
}

bool IsAllowedWebUrl(const GURL& url) {
  if (!url.is_valid()) {
    return false;
  }
  if (url.SchemeIsHTTPOrHTTPS()) {
    return true;
  }
  if (!url.SchemeIsBlob()) {
    return false;
  }
  const url::Origin origin = url::Origin::Create(url);
  return !origin.opaque() && (origin.scheme() == url::kHttpScheme ||
                              origin.scheme() == url::kHttpsScheme);
}

bool IsAllowedBrowserOperation(RemoteCdpTargetOperation operation) {
  switch (operation) {
    case RemoteCdpTargetOperation::kEnumerate:
    case RemoteCdpTargetOperation::kWebSocketConnect:
    case RemoteCdpTargetOperation::kGetInfo:
    case RemoteCdpTargetOperation::kAttach:
      return true;
    case RemoteCdpTargetOperation::kCreate:
    case RemoteCdpTargetOperation::kNavigate:
    case RemoteCdpTargetOperation::kActivate:
    case RemoteCdpTargetOperation::kClose:
    case RemoteCdpTargetOperation::kExposeDevToolsProtocol:
    case RemoteCdpTargetOperation::kOpenDevTools:
      return false;
  }
  return false;
}

}  // namespace

bool ShouldAllowRemoteCdpTargetOperation(RemoteCdpTargetOperation operation,
                                         std::string_view type,
                                         const GURL& url) {
  // These commands turn a page target into a browser-protocol bridge or open
  // a privileged local DevTools UI. They are never needed for remote browser
  // automation and must not inherit the page URL allowance.
  if (operation == RemoteCdpTargetOperation::kExposeDevToolsProtocol ||
      operation == RemoteCdpTargetOperation::kOpenDevTools) {
    return false;
  }

  // Playwright 建立 browser 级 CDP 会话需要 browser target。发现和自动附加
  // 是无 target 的会话命令，不在这里判断；它们产出的具体 target 分别走
  // kEnumerate 和 kAttach。
  if (type == "browser") {
    return IsAllowedBrowserOperation(operation);
  }

  // 使用 target 类型白名单，避免新的/未知 DevToolsAgentHost 类型仅因恰好
  // 带 HTTP URL 就自动进入远程攻击面。
  if (!IsRemoteWebTargetType(type)) {
    return false;
  }

  // Playwright-style clients bootstrap a new page at about:blank. Creation is
  // safe only as the first half of a two-part gate: content records the target
  // on the creating root client, and every later operation rechecks that exact
  // ownership. Other clients still cannot enumerate or attach to blank pages.
  if (operation == RemoteCdpTargetOperation::kCreate &&
      url.spec() == url::kAboutBlankURL) {
    return true;
  }

  // 普通网页 target 的其余操作共享同一 URL 边界。内部页、本地文件、
  // data/blob/扩展页以及无效 URL 都默认拒绝。
  return IsAllowedWebUrl(url);
}

bool ShouldExposeRemoteCdpTarget(std::string_view type, const GURL& url) {
  return ShouldAllowRemoteCdpTargetOperation(
      RemoteCdpTargetOperation::kEnumerate, type, url);
}

}  // namespace aegis
