// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_tab_helper.cc

#include "chrome/browser/aegis/aegis_phish_tab_helper.h"

#include <cstdint>
#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/common/aegis/builtin_phish_hosts.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "ui/base/page_transition_types.h"

namespace aegis {

PhishTabHelper::PhishTabHelper(content::WebContents* web_contents)
    : content::WebContentsObserver(web_contents),
      content::WebContentsUserData<PhishTabHelper>(*web_contents) {}

PhishTabHelper::~PhishTabHelper() = default;

std::optional<PhishAssessment> PhishTabHelper::TakeStashedAssessment(
    const GURL& url) {
  if (!stashed_ || stashed_url_ != url) {
    return std::nullopt;
  }
  std::optional<PhishAssessment> out = std::move(stashed_);
  stashed_.reset();
  stashed_url_ = GURL();
  return out;
}

void PhishTabHelper::DOMContentLoaded(
    content::RenderFrameHost* render_frame_host) {
  if (!render_frame_host || !render_frame_host->IsInPrimaryMainFrame()) {
    return;
  }
  if (checking_) {
    return;
  }

  AegisService* service = AegisService::GetInstance();
  if (!service->IsPhishInterstitialEnabled()) {
    return;
  }

  const GURL url = render_frame_host->GetLastCommittedURL();
  if (!url.SchemeIsHTTPOrHTTPS() || !url.has_host()) {
    return;
  }
  if (service->IsPhishHostAllowedForSession(std::string(url.host()))) {
    return;
  }

  PhishAssessment url_score = AssessPhishingUrl(url);
  if (MatchesBuiltinPhishRule(url) || url_score.should_block ||
      url_score.score == 0) {
    return;
  }

  checking_ = true;
  auto client = std::make_unique<
      mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>();
  render_frame_host->GetRemoteAssociatedInterfaces()->GetInterface(
      client.get());
  if (!client->is_bound()) {
    checking_ = false;
    return;
  }
  chrome::mojom::ChromeRenderFrame* raw = client->get();
  const GURL url_copy = url;
  raw->CollectAegisPageSignals(base::BindOnce(
      [](std::unique_ptr<
             mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>
             keep_alive,
         base::WeakPtr<PhishTabHelper> self, const GURL& url,
         int32_t password_fields, int32_t forms, const std::string& title,
         const std::string& text_sample) {
        if (!self) {
          return;
        }
        self->checking_ = false;
        self->OnPageSignals(url, password_fields, forms, title, text_sample);
      },
      std::move(client), weak_factory_.GetWeakPtr(), url_copy));
}

void PhishTabHelper::OnPageSignals(const GURL& url,
                                   int32_t password_fields,
                                   int32_t forms,
                                   const std::string& title,
                                   const std::string& text_sample) {
  content::WebContents* contents = web_contents();
  if (!contents) {
    return;
  }
  if (contents->GetLastCommittedURL() != url) {
    return;
  }

  AegisService* service = AegisService::GetInstance();
  if (!service->IsPhishInterstitialEnabled() ||
      service->IsPhishHostAllowedForSession(std::string(url.host()))) {
    return;
  }

  PhishAssessment assessment = ApplyPageSignals(AssessPhishingUrl(url),
                                                PageSignals{
                                                    .title = title,
                                                    .text_sample = text_sample,
                                                    .password_fields =
                                                        password_fields,
                                                    .forms = forms,
                                                });
  if (!assessment.should_block) {
    return;
  }

  LOG(INFO) << "Aegis: page-sense phishing score=" << assessment.score
            << " url=" << url;
  stashed_ = std::move(assessment);
  stashed_url_ = url;

  content::NavigationController::LoadURLParams params(url);
  params.transition_type = ui::PAGE_TRANSITION_RELOAD;
  params.should_replace_current_entry = true;
  contents->GetController().LoadURLWithParams(params);
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(PhishTabHelper);

}  // namespace aegis
