// Copyright 2026 GCSA

#include "chrome/browser/aegis/summary_session.h"

#include <cstdint>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/aegis/model_provider_client.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"

namespace aegis {
namespace {

constexpr base::TimeDelta kSummaryConfirmationTtl = base::Minutes(1);
constexpr size_t kMaxCaptureUrlBytes = 8192;
constexpr size_t kMaxCaptureTitleBytes = 4096;
constexpr size_t kMaxCaptureTextBytes = 64 * 1024;
constexpr int32_t kMaxCaptureFieldCount = 1'000'000;

SummarizeResult SessionError(std::string error) {
  SummarizeResult result;
  result.error = std::move(error);
  return result;
}

int Utf16Length(std::string_view value) {
  return static_cast<int>(base::UTF8ToUTF16(value).size());
}

}  // namespace

SummarySession::SummarySession(content::WebContents* source, std::string locale)
    : source_document_(source && source->GetPrimaryMainFrame()
                           ? source->GetPrimaryMainFrame()->GetWeakDocumentPtr()
                           : content::WeakDocumentPtr()),
      source_url_(source ? source->GetLastCommittedURL() : GURL()),
      locale_(std::move(locale)) {}

SummarySession::~SummarySession() {
  Cancel();
}

void SummarySession::Begin(PreviewCallback done) {
  if (state_ != State::kIdle) {
    Preview preview;
    preview.error = "summary session already started";
    std::move(done).Run(std::move(preview));
    return;
  }
  preview_callback_ = std::move(done);

  if (!IsSourceCurrent()) {
    Preview preview;
    preview.error = "source page is unavailable or has navigated";
    FinishPreview(std::move(preview));
    return;
  }
  if (!IsSourceProfileAllowed()) {
    Preview preview;
    preview.error = "summary is unavailable for this profile";
    FinishPreview(std::move(preview));
    return;
  }
  AegisService* service = AegisService::GetInstance();
  if (!service->IsPrivacyAiEnabled() || !service->IsPolicyWorkerEnabled()) {
    Preview preview;
    preview.error = "privacy summary or policy worker disabled";
    FinishPreview(std::move(preview));
    return;
  }

  content::RenderFrameHost* frame = source_document_.AsRenderFrameHostIfValid();
  frame->GetRemoteAssociatedInterfaces()->GetInterface(&capture_client_);
  if (!capture_client_.is_bound()) {
    Preview preview;
    preview.error = "page renderer is unavailable";
    FinishPreview(std::move(preview));
    return;
  }

  state_ = State::kCapturing;
  capture_client_.set_disconnect_handler(base::BindOnce(
      &SummarySession::OnCaptureDisconnected, weak_factory_.GetWeakPtr()));
  capture_client_->CollectAegisPageSignals(
      /*include_text=*/true, base::BindOnce(&SummarySession::OnPageSignals,
                                            weak_factory_.GetWeakPtr()));
}

void SummarySession::Confirm(ResultCallback done) {
  if (state_ != State::kAwaitingConfirmation || !original_ || !prepared_) {
    std::move(done).Run(SessionError("summary is not awaiting confirmation"));
    return;
  }
  if (base::TimeTicks::Now() - prepared_at_ > kSummaryConfirmationTtl) {
    state_ = State::kFinished;
    original_.reset();
    prepared_.reset();
    std::move(done).Run(SessionError("summary confirmation expired"));
    return;
  }
  if (!IsSourceCurrent()) {
    state_ = State::kFinished;
    original_.reset();
    prepared_.reset();
    std::move(done).Run(SessionError("page navigated before confirmation"));
    return;
  }
  if (!IsSourceProfileAllowed()) {
    state_ = State::kFinished;
    original_.reset();
    prepared_.reset();
    std::move(done).Run(
        SessionError("summary profile changed before confirmation"));
    return;
  }

  PageSnapshot original = std::move(*original_);
  PreparedSummary prepared = std::move(*prepared_);
  original_.reset();
  prepared_.reset();
  state_ = State::kRunning;
  result_callback_ = std::move(done);

  std::optional<std::string> request_id =
      AegisService::GetInstance()->SummarizePreparedPage(
          std::move(original), std::move(prepared), locale_, provider_,
          base_url_, model_,
          base::BindOnce(&SummarySession::FinishResult,
                         weak_factory_.GetWeakPtr()));
  // Feature/configuration/sensitive-page paths may complete synchronously.
  if (state_ == State::kRunning) {
    active_request_id_ = std::move(request_id);
    if (!active_request_id_) {
      FinishResult(SessionError("summary request did not start"));
    }
  }
}

void SummarySession::Cancel() {
  if (state_ == State::kCancelled || state_ == State::kFinished) {
    return;
  }
  capture_client_.reset();
  if (active_request_id_) {
    AegisService* service = AegisService::GetInstance();
    if (IsSourceProfileAllowed()) {
      service->CancelModelSummaryRequest(*active_request_id_);
    }
    active_request_id_.reset();
  }
  original_.reset();
  prepared_.reset();
  preview_callback_.Reset();
  result_callback_.Reset();
  weak_factory_.InvalidateWeakPtrs();
  state_ = State::kCancelled;
}

bool SummarySession::IsSourceCurrent() const {
  content::RenderFrameHost* frame = source_document_.AsRenderFrameHostIfValid();
  content::WebContents* contents =
      frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  return frame && contents && contents->GetPrimaryMainFrame() == frame &&
         !frame->IsErrorDocument() && source_url_.SchemeIsHTTPOrHTTPS() &&
         frame->GetLastCommittedURL() == source_url_ &&
         contents->GetLastCommittedURL() == source_url_;
}

bool SummarySession::IsSourceProfileAllowed() const {
  content::RenderFrameHost* frame = source_document_.AsRenderFrameHostIfValid();
  content::WebContents* contents =
      frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  Profile* profile =
      contents ? Profile::FromBrowserContext(contents->GetBrowserContext())
               : nullptr;
  return AegisService::GetInstance()->IsInitializedForProfile(profile);
}

void SummarySession::OnCaptureDisconnected() {
  if (state_ != State::kCapturing) {
    return;
  }
  capture_client_.reset();
  Preview preview;
  preview.error = "page renderer disconnected during capture";
  FinishPreview(std::move(preview));
}

void SummarySession::OnPageSignals(int32_t password_fields,
                                   int32_t forms,
                                   const std::vector<std::string>& form_actions,
                                   const std::string& title,
                                   const std::string& text_sample) {
  (void)form_actions;
  capture_client_.reset();
  if (state_ != State::kCapturing) {
    return;
  }
  if (!IsSourceCurrent() || source_url_.spec().size() > kMaxCaptureUrlBytes ||
      !base::IsStringUTF8(title) || !base::IsStringUTF8(text_sample) ||
      title.size() > kMaxCaptureTitleBytes ||
      text_sample.size() > kMaxCaptureTextBytes || password_fields < 0 ||
      password_fields > kMaxCaptureFieldCount || forms < 0 ||
      forms > kMaxCaptureFieldCount) {
    Preview preview;
    preview.error = "page navigated or returned invalid summary data";
    FinishPreview(std::move(preview));
    return;
  }
  if (!IsSourceProfileAllowed()) {
    Preview preview;
    preview.error = "summary profile changed during capture";
    FinishPreview(std::move(preview));
    return;
  }

  PageSnapshot original;
  original.url = source_url_.spec();
  original.title = title;
  original.text_sample = text_sample;
  original.password_fields = password_fields;
  original.forms = forms;
  std::optional<PreparedSummary> prepared =
      PrepareSummaryForBrowser(original, locale_);
  if (!prepared) {
    Preview preview;
    preview.error = "browser privacy preparation rejected the page";
    FinishPreview(std::move(preview));
    return;
  }

  AegisService* service = AegisService::GetInstance();
  provider_ = service->ConfiguredModelProvider();
  base_url_ = service->ConfiguredModelBaseUrl();
  model_ = service->ConfiguredModelName();

  Preview preview;
  preview.ok = true;
  preview.site = source_url_.host();
  preview.chars_read = Utf16Length(original.text_sample);
  preview.chars_redacted = Utf16Length(prepared->snapshot.text_sample);
  preview.provider = provider_;
  preview.base_url = base_url_;
  preview.model = model_;
  const std::optional<ModelProvider> provider = ParseModelProvider(provider_);
  preview.stayed_on_device =
      provider && IsLocalModelEndpoint(*provider, GURL(base_url_));
  preview.model_allowed =
      IsModelSummaryAllowed(original, &preview.model_block_reason);

  original_ = std::move(original);
  prepared_ = std::move(*prepared);
  prepared_at_ = base::TimeTicks::Now();
  state_ = State::kAwaitingConfirmation;
  FinishPreview(std::move(preview));
}

void SummarySession::FinishPreview(Preview preview) {
  if (!preview.ok && state_ != State::kCancelled) {
    state_ = State::kFinished;
  }
  if (preview_callback_) {
    std::move(preview_callback_).Run(std::move(preview));
  }
}

void SummarySession::FinishResult(SummarizeResult result) {
  if (state_ != State::kRunning) {
    return;
  }
  active_request_id_.reset();
  state_ = State::kFinished;
  if (result_callback_) {
    std::move(result_callback_).Run(std::move(result));
  }
}

}  // namespace aegis
