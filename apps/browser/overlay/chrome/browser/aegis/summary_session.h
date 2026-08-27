// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_SUMMARY_SESSION_H_
#define CHROME_BROWSER_AEGIS_SUMMARY_SESSION_H_

#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/summary_policy.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}

namespace aegis {

class SummarySessionTestPeer;

// Owns one native-popup summary attempt. Raw page text and the prepared model
// payload stay inside this object; the view receives only preview metadata and
// the final result.
class SummarySession {
 public:
  enum class State {
    kIdle,
    kCapturing,
    kAwaitingConfirmation,
    kRunning,
    kFinished,
    kCancelled,
  };

  struct Preview {
    bool ok = false;
    std::string error;
    std::string site;
    int chars_read = 0;
    int chars_redacted = 0;
    bool model_allowed = false;
    std::string model_block_reason;
    std::string provider;
    std::string base_url;
    std::string model;
    bool stayed_on_device = false;
  };

  using PreviewCallback = base::OnceCallback<void(Preview)>;
  using ResultCallback = base::OnceCallback<void(SummarizeResult)>;

  SummarySession(content::WebContents* source, std::string locale);
  SummarySession(const SummarySession&) = delete;
  SummarySession& operator=(const SummarySession&) = delete;
  ~SummarySession();

  void Begin(PreviewCallback done);
  void Confirm(ResultCallback done);
  void Cancel();

  State state() const { return state_; }

 private:
  friend class SummarySessionTestPeer;

  bool IsSourceCurrent() const;
  bool IsSourceProfileAllowed() const;
  void OnCaptureDisconnected();
  void OnPageSignals(int32_t password_fields,
                     int32_t forms,
                     const std::vector<std::string>& form_actions,
                     const std::string& title,
                     const std::string& text_sample);
  void FinishPreview(Preview preview);
  void FinishResult(SummarizeResult result);

  const content::WeakDocumentPtr source_document_;
  const GURL source_url_;
  const std::string locale_;

  State state_ = State::kIdle;
  base::TimeTicks prepared_at_;
  std::optional<PageSnapshot> original_;
  std::optional<PreparedSummary> prepared_;
  std::string provider_;
  std::string base_url_;
  std::string model_;
  std::optional<std::string> active_request_id_;
  PreviewCallback preview_callback_;
  ResultCallback result_callback_;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> capture_client_;
  base::WeakPtrFactory<SummarySession> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_SUMMARY_SESSION_H_
