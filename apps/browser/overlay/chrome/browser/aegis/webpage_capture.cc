// Copyright 2026 GCSA
#include "chrome/browser/aegis/webpage_capture.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "chrome/common/pref_names.h"
#include "components/lens/lens_metadata.mojom.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/browser/weak_document_ptr.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr size_t kMaxImage = 24 * 1024 * 1024;

class CaptureState : public content::WebContentsUserData<CaptureState>,
                     public content::WebContentsObserver,
                     public content::DevToolsAgentHostClient {
 public:
  explicit CaptureState(content::WebContents* contents)
      : content::WebContentsUserData<CaptureState>(*contents),
        content::WebContentsObserver(contents) {}
  ~CaptureState() override { Detach(); }

  void StartPage() {
    if (host_ || image_remote_ || external_operation_) {
      return;
    }
    source_ = web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    host_ = content::DevToolsAgentHost::GetOrCreateFor(web_contents());
    if (!host_->AttachClient(this)) {
      host_.reset();
      Show({});
      return;
    }
    timeout_.Start(FROM_HERE, base::Seconds(10),
                   base::BindOnce(&CaptureState::Show, weak_.GetWeakPtr(),
                                  CapturedWebpage()));
    Send(1, "Page.getLayoutMetrics", {});
  }

  void StartImage(content::RenderFrameHost& frame) {
    if (host_ || image_remote_ || external_operation_) {
      return;
    }
    source_ = frame.GetWeakDocumentPtr();
    frame.GetRemoteAssociatedInterfaces()->GetInterface(&image_remote_);
    timeout_.Start(FROM_HERE, base::Seconds(10),
                   base::BindOnce(&CaptureState::Show, weak_.GetWeakPtr(),
                                  CapturedWebpage{.ocr = true}));
    image_remote_->RequestImageForContextNode(
        0, gfx::Size(3000, 3000), chrome::mojom::ImageFormat::PNG,
        chrome::mojom::kDefaultQuality,
        base::BindOnce(&CaptureState::ImageReady, weak_.GetWeakPtr()));
  }

  CapturedWebpage Take() { return std::exchange(pending_, {}); }

  int BeginExternalPage() {
    if (host_ || image_remote_ || external_operation_) {
      return 0;
    }
    source_ = web_contents()->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    if (next_operation_ == 0x7fffffff) {
      next_operation_ = 0;
    }
    external_operation_ = ++next_operation_;
    timeout_.Start(FROM_HERE, base::Seconds(14),
                   base::BindOnce(&CaptureState::Show, weak_.GetWeakPtr(),
                                  CapturedWebpage()));
    return external_operation_;
  }

  void FinishExternalPage(int operation, const std::string& png) {
    if (operation == 0 || operation != external_operation_) {
      return;
    }
    Show({.png = png.size() <= kMaxImage * 3 / 4 ? base::Base64Encode(png) : "",
          .too_large = png.size() > kMaxImage * 3 / 4});
  }

  void DispatchProtocolMessage(content::DevToolsAgentHost* host,
                               base::span<const uint8_t> bytes) override {
    if (host != host_.get() || bytes.size() > kMaxImage * 2) {
      return;
    }
    const auto reply = base::JSONReader::ReadDict(
        std::string_view(reinterpret_cast<const char*>(bytes.data()),
                         bytes.size()),
        base::JSON_PARSE_RFC);
    if (!reply) {
      return;
    }
    const auto id = reply->FindInt("id");
    const auto* result = reply->FindDict("result");
    if (id == 1) {
      const auto* size = result ? result->FindDict("cssContentSize") : nullptr;
      const auto width = size ? size->FindDouble("width") : std::nullopt;
      const auto height = size ? size->FindDouble("height") : std::nullopt;
      auto* view = web_contents()->GetRenderWidgetHostView();
      if (!view || !width || !height || !std::isfinite(*width) ||
          !std::isfinite(*height) || *width < 1 || *height < 1) {
        QueueShow({});
        return;
      }
      if (*width > 4096 || *height > 36000 || *width * *height > 16'000'000) {
        QueueShow({.too_large = true});
        return;
      }
      base::DictValue clip;
      clip.Set("x", 0);
      clip.Set("y", 0);
      clip.Set("width", *width);
      clip.Set("height", *height);
      const double scale = std::min(
          1.0, std::sqrt(16'000'000 / (*width * *height)) /
                   std::max(1.0f, view->GetDeviceScaleFactor()));
      clip.Set("scale", scale);
      base::DictValue parameters;
      parameters.Set("format", "png");
      parameters.Set("fromSurface", true);
      parameters.Set("captureBeyondViewport", true);
      parameters.Set("clip", std::move(clip));
      Send(2, "Page.captureScreenshot", std::move(parameters));
    } else if (id == 2) {
      const auto* data = result ? result->FindString("data") : nullptr;
      QueueShow({.png = data && data->size() <= kMaxImage ? *data : "",
                 .too_large = data && data->size() > kMaxImage});
    }
  }

  void AgentHostClosed(content::DevToolsAgentHost*) override {
    host_.reset();
    QueueShow({});
  }
  bool MayAttachToURL(const GURL& url, bool is_webui) override {
    return !is_webui && url.SchemeIsHTTPOrHTTPS();
  }
  bool MayReadLocalFiles() override { return false; }
  bool MayWriteLocalFiles() override { return false; }

  void PrimaryPageChanged(content::Page&) override {
    timeout_.Stop();
    weak_.InvalidateWeakPtrs();
    Detach();
    if (web_contents()->GetLastCommittedURL() != GURL(kCapturePageUrl)) {
      pending_ = {};
    }
  }

 private:
  friend class content::WebContentsUserData<CaptureState>;

  void Send(int id, const char* method, base::DictValue parameters) {
    base::DictValue request;
    request.Set("id", id);
    request.Set("method", method);
    request.Set("params", std::move(parameters));
    const auto json = base::WriteJson(request);
    if (host_ && json) {
      host_->DispatchProtocolMessage(this, base::as_byte_span(*json));
    }
  }

  void ImageReady(const std::vector<uint8_t>& bytes,
                  const gfx::Size& original_size,
                  const gfx::Size& result_size,
                  const std::string& mime,
                  std::vector<lens::mojom::LatencyLogPtr> logs) {
    QueueShow({.png = bytes.size() <= kMaxImage && mime == "image/png"
                          ? base::Base64Encode(bytes)
                          : "",
               .ocr = true});
  }

  void QueueShow(CapturedWebpage capture) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CaptureState::Show, weak_.GetWeakPtr(),
                                 std::move(capture)));
  }

  void Show(CapturedWebpage capture) {
    timeout_.Stop();
    Detach();
    auto* frame = source_.AsRenderFrameHostIfValid();
    source_ = {};
    auto* contents = web_contents();
    if (!frame || !frame->IsActive() || !CanCaptureWebpage(contents) ||
        contents->GetVisibility() != content::Visibility::VISIBLE) {
      return;
    }
    pending_ = std::move(capture);
    contents->GetController().LoadURL(GURL(kCapturePageUrl), content::Referrer(),
                                     ui::PAGE_TRANSITION_AUTO_TOPLEVEL, "");
  }

  void Detach() {
    external_operation_ = 0;
    image_remote_.reset();
    if (host_) {
      auto host = std::move(host_);
      host->DetachClient(this);
    }
  }

  CapturedWebpage pending_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> image_remote_;
  content::WeakDocumentPtr source_;
  int external_operation_ = 0;
  int next_operation_ = 0;
  base::OneShotTimer timeout_;
  base::WeakPtrFactory<CaptureState> weak_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(CaptureState);

}  // namespace

bool CanCaptureWebpage(content::WebContents* contents) {
  return contents && contents->GetPrimaryMainFrame() &&
         contents->GetLastCommittedURL().SchemeIsHTTPOrHTTPS() &&
         !Profile::FromBrowserContext(contents->GetBrowserContext())
              ->GetPrefs()
              ->GetBoolean(prefs::kDisableScreenshots);
}

void CaptureFullWebpage(content::WebContents* contents) {
  if (CanCaptureWebpage(contents)) {
    CaptureState::GetOrCreateForWebContents(contents)->StartPage();
  }
}

void CaptureContextImage(content::RenderFrameHost* frame) {
  if (!frame || !frame->IsActive()) {
    return;
  }
  auto* contents = content::WebContents::FromRenderFrameHost(frame);
  if (CanCaptureWebpage(contents)) {
    CaptureState::GetOrCreateForWebContents(contents)->StartImage(*frame);
  }
}

int BeginExternalPageCapture(content::WebContents* contents) {
  return CanCaptureWebpage(contents)
             ? CaptureState::GetOrCreateForWebContents(contents)->BeginExternalPage()
             : 0;
}

void FinishExternalPageCapture(content::WebContents* contents,
                               int operation,
                               std::string png) {
  if (!contents) {
    return;
  }
  if (auto* state = CaptureState::FromWebContents(contents)) {
    state->FinishExternalPage(operation, png);
  }
}

CapturedWebpage TakeCapturedWebpage(content::WebContents* contents) {
  auto* state = CaptureState::FromWebContents(contents);
  return state ? state->Take() : CapturedWebpage();
}

}  // namespace aegis
