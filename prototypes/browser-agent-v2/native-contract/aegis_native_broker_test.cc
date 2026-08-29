#include "aegis_native_broker.h"

#include <cstdlib>
#include <iostream>
#include <string>

namespace {

using aegis::agent_v2::ActionKind;
using aegis::agent_v2::ActionRequest;
using aegis::agent_v2::ActionSource;
using aegis::agent_v2::DocumentRef;
using aegis::agent_v2::NativeActionBroker;

int assertions = 0;

void Expect(bool condition, const std::string& message) {
  ++assertions;
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
    std::exit(1);
  }
}

}  // namespace

int main() {
  NativeActionBroker broker("isolated-profile",
                            {"https://fixture.test", "https://search.test"});

  // E0：任务可从空白页绑定文档并主动导航，不依赖预先打开的目标页。
  const DocumentRef blank = broker.BindDocument(7, "about:blank");
  const ActionRequest discover{ActionKind::kNavigate,
                               ActionSource::kTrustedPlanner, blank,
                               "https://search.test"};
  Expect(broker.Evaluate(discover).allowed, "E0 discovery navigation");
  const DocumentRef search = broker.CommitNavigation(discover);
  Expect(search.document_id != blank.document_id,
         "navigation rotates document identity");

  // 旧文档动作必须在导航后失效。
  const ActionRequest stale_click{ActionKind::kClick,
                                  ActionSource::kTrustedPlanner, blank, ""};
  Expect(broker.Evaluate(stale_click).reason == "stale_document",
         "stale action rejected");

  // E7：可信 Planner 可请求原生收藏夹；页面文本不能自行授予原生能力。
  const ActionRequest bookmark{ActionKind::kCreateBookmark,
                               ActionSource::kTrustedPlanner, search, ""};
  Expect(broker.Evaluate(bookmark).allowed, "trusted native bookmark");
  const ActionRequest injected_bookmark{ActionKind::kCreateBookmark,
                                        ActionSource::kUntrustedPage, search,
                                        ""};
  Expect(!broker.Evaluate(injected_bookmark).allowed,
         "page cannot grant bookmark capability");

  // E8：提示注入不能升级为上传或最终交易。
  const ActionRequest injected_upload{ActionKind::kUploadFile,
                                      ActionSource::kUntrustedPage, search,
                                      ""};
  Expect(broker.Evaluate(injected_upload).reason ==
             "untrusted_page_cannot_grant_capability",
         "prompt injection denied");

  // E9：重定向目标必须在提交导航前经过 Browser Process 级 allowlist。
  const ActionRequest redirect{ActionKind::kNavigate,
                               ActionSource::kTrustedPlanner, search,
                               "https://blocked.test"};
  Expect(broker.Evaluate(redirect).reason == "origin_not_allowed",
         "cross-origin redirect denied before commit");

  // 最终购买无论来源如何都必须交还用户。
  const ActionRequest purchase{ActionKind::kFinalPurchase,
                               ActionSource::kTrustedPlanner, search, ""};
  const auto purchase_decision = broker.Evaluate(purchase);
  Expect(!purchase_decision.allowed &&
             purchase_decision.requires_user_handoff,
         "final purchase requires handoff");

  // Profile 身份是能力的一部分。
  DocumentRef wrong_profile = search;
  wrong_profile.profile_id = "daily-profile";
  const ActionRequest cross_profile{ActionKind::kObserve,
                                    ActionSource::kTrustedPlanner,
                                    wrong_profile, ""};
  Expect(broker.Evaluate(cross_profile).reason == "profile_mismatch",
         "cross-profile action denied");

  // E11：Stop 清空文档租约，任何排队旧动作都不能重放。
  broker.Stop();
  Expect(broker.stopped(), "task stopped");
  Expect(broker.Evaluate(bookmark).reason == "task_stopped",
         "queued action cannot replay after stop");
  Expect(broker.committed_action_count() == 1,
         "only the approved navigation was committed");

  std::cout << "{\"status\":\"passed\",\"assertions\":" << assertions
            << ",\"scenarios\":[\"E0\",\"E7\",\"E8\",\"E9\",\"E11\"]}"
            << '\n';
  return 0;
}
