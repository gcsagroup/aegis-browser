// Copyright 2026 GCSA
// Native browser-data tools used by Aegis Browser Agent.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AEGIS_BROWSER_TOOLS_H_
#define CHROME_BROWSER_AEGIS_AGENT_AEGIS_BROWSER_TOOLS_H_

#include <cstddef>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/cancelable_task_tracker.h"
#include "chrome/browser/aegis/agent/agent_task.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/undo/undo_manager_observer.h"

class Profile;

template <class T>
class scoped_refptr;

namespace net {
class HttpResponseHeaders;
struct RedirectInfo;
}  // namespace net

namespace network::mojom {
class URLResponseHead;
}

namespace download {
class DownloadItem;
}

class UndoManager;

namespace history {
class QueryResults;
}

namespace aegis::agent {

bool IsAegisBookmarkUrlCheckTargetAllowed(const AgentTaskScope& scope,
                                          const GURL& selected_bookmark_url,
                                          const GURL& target);
void CancelAegisOwnedDownloadOnTaskStop(download::DownloadItem* item);

// Executes browser-owned tools that must not be implemented through renderer
// script. Every mutating method revalidates an opaque browser snapshot before
// changing state.
class AegisBrowserTools : public UndoManagerObserver {
 public:
  using ToolResultCallback = base::OnceCallback<void(AgentToolResult)>;

  explicit AegisBrowserTools(Profile* profile);
  AegisBrowserTools(const AegisBrowserTools&) = delete;
  AegisBrowserTools& operator=(const AegisBrowserTools&) = delete;
  ~AegisBrowserTools() override;

  bool CanHandle(std::string_view tool_name) const;
  void Execute(AgentTask* task,
               const AgentToolCall& call,
               ToolResultCallback callback);
  void ForgetTask(const std::string& task_id,
                  bool preserve_bookmark_undo = false,
                  bool cancel_active_downloads = false);

 private:
  friend class AegisBrowserToolsTestPeer;

  struct BookmarkMove {
    std::string node_uuid;
    std::u16string category;
  };

  struct BookmarkPlan {
    std::string task_id;
    std::string plan_id;
    std::string snapshot_hash;
    std::vector<BookmarkMove> moves;
  };

  struct BookmarkUndoReceipt {
    std::string task_id;
    std::string token;
    std::string before_hash;
    std::string after_hash;
    size_t undo_count = 0;
  };

  struct UrlCheckBatch;

  void ExecuteTabTool(AgentTask* task,
                      const AgentToolCall& call,
                      ToolResultCallback callback);
  void ExecuteBookmarkTool(AgentTask* task,
                           const AgentToolCall& call,
                           ToolResultCallback callback);
  void ExecuteWindowTool(AgentTask* task,
                         const AgentToolCall& call,
                         ToolResultCallback callback);
  void ExecuteWorkspaceTool(AgentTask* task,
                            const AgentToolCall& call,
                            ToolResultCallback callback);
  void ExecuteHistoryTool(AgentTask* task,
                          const AgentToolCall& call,
                          ToolResultCallback callback);
  void ExecutePermissionsTool(AgentTask* task,
                              const AgentToolCall& call,
                              ToolResultCallback callback);
  void ExecuteDownloadTool(AgentTask* task,
                           const AgentToolCall& call,
                           ToolResultCallback callback);
  void OnDownloadStarted(std::string pending_token,
                         const std::string& task_id,
                         AgentTaskScope scope,
                         std::string action_id,
                         std::string expected_sha256,
                         ToolResultCallback callback,
                         download::DownloadItem* item,
                         download::DownloadInterruptReason reason);
  void PumpUrlCheckRequests(const std::string& batch_key);
  void StartUrlCheckRequest(const std::string& batch_key, size_t index);
  void OnUrlCheckRedirect(const std::string& batch_key,
                          size_t index,
                          const GURL& url_before_redirect,
                          const net::RedirectInfo& redirect_info,
                          const network::mojom::URLResponseHead& response_head,
                          std::vector<std::string>* removed_headers);
  void OnUrlCheckComplete(
      const std::string& batch_key,
      size_t index,
      scoped_refptr<net::HttpResponseHeaders> response_headers);
  void OnHistorySearch(AgentTaskScope scope,
                       std::string action_id,
                       std::string domain,
                       ToolResultCallback callback,
                       history::QueryResults results);
  void ObserveBookmarkUndoManager(UndoManager* undo_manager);
  void StopObservingBookmarkUndoManager();
  void OnUndoManagerStateChange() override;
  void OnUndoManagerShutdown() override;

  raw_ptr<Profile> profile_;
  std::map<std::string, BookmarkPlan> bookmark_plans_;
  std::map<std::string, BookmarkUndoReceipt> bookmark_undo_receipts_;
  std::map<std::string, std::unique_ptr<UrlCheckBatch>> url_check_batches_;
  std::map<std::string, base::flat_set<std::string>> owned_downloads_;
  std::map<std::string, std::string> pending_download_tasks_;
  std::map<std::string, std::string> expected_download_hashes_;
  raw_ptr<UndoManager> bookmark_undo_manager_ = nullptr;
  base::CancelableTaskTracker history_task_tracker_;
  base::WeakPtrFactory<AegisBrowserTools> weak_ptr_factory_{this};
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AEGIS_BROWSER_TOOLS_H_
