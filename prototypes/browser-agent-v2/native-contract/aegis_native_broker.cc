#include "aegis_native_broker.h"

#include <stdexcept>
#include <utility>

namespace aegis::agent_v2 {

NativeActionBroker::NativeActionBroker(
    std::string profile_id,
    std::set<std::string> allowed_origins)
    : profile_id_(std::move(profile_id)),
      allowed_origins_(std::move(allowed_origins)) {}

DocumentRef NativeActionBroker::BindDocument(int tab_id,
                                              const std::string& origin) {
  if (stopped_) {
    throw std::logic_error("task_stopped");
  }
  DocumentRef document{profile_id_, tab_id, next_document_id_++, origin};
  documents_[tab_id] = document;
  return document;
}

PolicyDecision NativeActionBroker::Evaluate(
    const ActionRequest& request) const {
  if (stopped_) {
    return {false, false, "task_stopped"};
  }
  if (request.document.profile_id != profile_id_) {
    return {false, false, "profile_mismatch"};
  }
  if (!IsCurrentDocument(request.document)) {
    return {false, false, "stale_document"};
  }
  if (request.source == ActionSource::kUntrustedPage &&
      (request.kind == ActionKind::kCreateBookmark ||
       request.kind == ActionKind::kUploadFile ||
       request.kind == ActionKind::kFinalPurchase)) {
    return {false, false, "untrusted_page_cannot_grant_capability"};
  }
  if (request.kind == ActionKind::kNavigate &&
      !allowed_origins_.contains(request.target_origin)) {
    return {false, false, "origin_not_allowed"};
  }
  if (request.kind == ActionKind::kUploadFile) {
    return {false, true, "private_upload_requires_user"};
  }
  if (request.kind == ActionKind::kFinalPurchase) {
    return {false, true, "final_purchase_requires_user"};
  }
  return {true, false, "allowed"};
}

DocumentRef NativeActionBroker::CommitNavigation(
    const ActionRequest& request) {
  const PolicyDecision decision = Evaluate(request);
  if (!decision.allowed || request.kind != ActionKind::kNavigate) {
    throw std::logic_error(decision.reason);
  }
  ++committed_action_count_;
  return BindDocument(request.document.tab_id, request.target_origin);
}

void NativeActionBroker::Stop() {
  stopped_ = true;
  documents_.clear();
}

bool NativeActionBroker::IsCurrentDocument(
    const DocumentRef& document) const {
  const auto iterator = documents_.find(document.tab_id);
  return iterator != documents_.end() &&
         iterator->second.document_id == document.document_id &&
         iterator->second.origin == document.origin;
}

}  // namespace aegis::agent_v2
