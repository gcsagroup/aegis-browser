// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_OBSERVATION_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_OBSERVATION_H_

#include <cstddef>
#include <map>
#include <string>
#include <string_view>

#include "base/values.h"
#include "url/gurl.h"
namespace optimization_guide::proto {
class ContentNode;
}
namespace aegis::agent {
struct AgentObservationNodes {
  base::ListValue nodes;
  bool truncated = false;
  // 仅供浏览器绑定动作；完整链接不放入发往模型的nodes。
  std::map<int, GURL> download_links;
};
// 原生授权范围决定是否需要交互控件；只读任务保留正文、表格与来源节点。
AgentObservationNodes BuildAgentObservationNodes(
    const optimization_guide::proto::ContentNode& root,
    bool interactive,
    bool capture_download_links = false);
// 对有界副本复用摘要脱敏，最终结果仍受UTF-8字节上限约束。
std::string BoundedAgentObservationText(std::string_view text,
                                        size_t remaining);
}  // namespace aegis::agent
#endif
