#ifndef AEGIS_BROWSER_AGENT_V2_NATIVE_CONTRACT_AEGIS_NATIVE_BROKER_H_
#define AEGIS_BROWSER_AGENT_V2_NATIVE_CONTRACT_AEGIS_NATIVE_BROKER_H_

#include <cstdint>
#include <map>
#include <set>
#include <string>

namespace aegis::agent_v2 {

enum class ActionKind {
  kNavigate,
  kObserve,
  kClick,
  kCreateBookmark,
  kUploadFile,
  kFinalPurchase,
};

enum class ActionSource {
  kTrustedPlanner,
  kUntrustedPage,
};

struct DocumentRef {
  std::string profile_id;
  int tab_id = 0;
  uint64_t document_id = 0;
  std::string origin;
};

struct ActionRequest {
  ActionKind kind = ActionKind::kObserve;
  ActionSource source = ActionSource::kTrustedPlanner;
  DocumentRef document;
  std::string target_origin;
};

struct PolicyDecision {
  bool allowed = false;
  bool requires_user_handoff = false;
  std::string reason;
};

class NativeActionBroker {
 public:
  NativeActionBroker(std::string profile_id,
                     std::set<std::string> allowed_origins);

  DocumentRef BindDocument(int tab_id, const std::string& origin);
  PolicyDecision Evaluate(const ActionRequest& request) const;
  DocumentRef CommitNavigation(const ActionRequest& request);
  void Stop();

  bool stopped() const { return stopped_; }
  size_t committed_action_count() const { return committed_action_count_; }

 private:
  bool IsCurrentDocument(const DocumentRef& document) const;

  const std::string profile_id_;
  const std::set<std::string> allowed_origins_;
  std::map<int, DocumentRef> documents_;
  uint64_t next_document_id_ = 1;
  size_t committed_action_count_ = 0;
  bool stopped_ = false;
};

}  // namespace aegis::agent_v2

#endif  // AEGIS_BROWSER_AGENT_V2_NATIVE_CONTRACT_AEGIS_NATIVE_BROKER_H_
