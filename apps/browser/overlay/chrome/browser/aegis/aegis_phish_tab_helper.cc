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
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
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

void PhishTabHelper::AllowNextNavigationOnce(const GURL& url) {
  // The interstitial can proceed to the same URL. Invalidate any renderer
  // response still pending for the document which caused the interstitial so
  // it cannot be mistaken for a response from the replacement document.
  InvalidatePageSignalCheck();
  one_time_bypass_url_ = url;
  bypassed_navigation_url_ = GURL();
  bypassed_navigation_id_.reset();
  bypassed_document_ = content::WeakDocumentPtr();
  stashed_.reset();
  stashed_url_ = GURL();
}

bool PhishTabHelper::ConsumeOneTimeNavigationBypass(const GURL& url,
                                                    int64_t navigation_id) {
  bypassed_navigation_url_ = GURL();
  bypassed_navigation_id_.reset();
  bypassed_document_ = content::WeakDocumentPtr();
  if (!one_time_bypass_url_.is_valid()) {
    return false;
  }
  const bool matches = one_time_bypass_url_ == url;
  one_time_bypass_url_ = GURL();
  if (!matches) {
    return false;
  }
  bypassed_navigation_url_ = url;
  bypassed_navigation_id_ = navigation_id;
  return true;
}

void PhishTabHelper::CancelOneTimeNavigationBypass(int64_t navigation_id) {
  if (!bypassed_navigation_id_ || *bypassed_navigation_id_ != navigation_id) {
    return;
  }
  bypassed_navigation_url_ = GURL();
  bypassed_navigation_id_.reset();
  bypassed_document_ = content::WeakDocumentPtr();
}

void PhishTabHelper::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle || !navigation_handle->IsInPrimaryMainFrame()) {
    return;
  }

  if (navigation_handle->HasCommitted() &&
      !navigation_handle->IsSameDocument()) {
    InvalidatePageSignalCheck();
  }

  // A permit which was not consumed by the matching navigation throttle must
  // not survive a failed navigation or a temporary feature-state change.
  one_time_bypass_url_ = GURL();
  if (!bypassed_navigation_id_ ||
      *bypassed_navigation_id_ != navigation_handle->GetNavigationId()) {
    return;
  }

  const GURL expected_url = bypassed_navigation_url_;
  bypassed_navigation_url_ = GURL();
  bypassed_navigation_id_.reset();
  bypassed_document_ = content::WeakDocumentPtr();
  if (!navigation_handle->HasCommitted() || navigation_handle->IsErrorPage() ||
      navigation_handle->GetURL() != expected_url) {
    return;
  }

  content::RenderFrameHost* render_frame_host =
      navigation_handle->GetRenderFrameHost();
  if (render_frame_host) {
    bypassed_document_ = render_frame_host->GetWeakDocumentPtr();
  }
}

void PhishTabHelper::DOMContentLoaded(
    content::RenderFrameHost* render_frame_host) {
  if (!render_frame_host || !render_frame_host->IsInPrimaryMainFrame()) {
    return;
  }
  // Security interstitials are committed as error documents. Their fixed UI
  // must never be treated as page content supplied by the blocked site.
  if (render_frame_host->IsErrorDocument()) {
    InvalidatePageSignalCheck();
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
  one_time_bypass_url_ = GURL();
  if (!url.SchemeIsHTTPOrHTTPS() || !url.has_host()) {
    return;
  }
  if (bypassed_document_.AsRenderFrameHostIfValid() == render_frame_host) {
    bypassed_document_ = content::WeakDocumentPtr();
    return;
  }

  PhishAssessment url_score = service->AssessPhishUrl(url);
  if (MatchesBuiltinPhishRule(url) || url_score.should_block) {
    return;
  }

  checking_ = true;
  checking_document_ = render_frame_host->GetWeakDocumentPtr();
  auto client = std::make_unique<
      mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame>>();
  render_frame_host->GetRemoteAssociatedInterfaces()->GetInterface(
      client.get());
  if (!client->is_bound()) {
    InvalidatePageSignalCheck();
    return;
  }
  client->set_disconnect_handler(base::BindOnce(
      &PhishTabHelper::OnPageSignalCollectionFailed, weak_factory_.GetWeakPtr(),
      render_frame_host->GetWeakDocumentPtr()));
  chrome::mojom::ChromeRenderFrame* raw = client->get();
  content::WeakDocumentPtr source_document =
      render_frame_host->GetWeakDocumentPtr();
  raw->CollectAegisPageSignals(
      url_score.score > 0,
      base::BindOnce(
          [](std::unique_ptr<mojo::AssociatedRemote<
                 chrome::mojom::ChromeRenderFrame>> keep_alive,
             base::WeakPtr<PhishTabHelper> self,
             content::WeakDocumentPtr source_document, int32_t password_fields,
             int32_t forms, const std::vector<std::string>& form_actions,
             const std::string& title, const std::string& text_sample) {
            if (!self) {
              return;
            }
            self->OnPageSignalsCollected(std::move(source_document),
                                         password_fields, forms, form_actions,
                                         title, text_sample);
          },
          std::move(client), weak_factory_.GetWeakPtr(),
          std::move(source_document)));
}

void PhishTabHelper::InvalidatePageSignalCheck() {
  checking_ = false;
  checking_document_ = content::WeakDocumentPtr();
  weak_factory_.InvalidateWeakPtrs();
}

void PhishTabHelper::OnPageSignalCollectionFailed(
    content::WeakDocumentPtr source_document) {
  content::RenderFrameHost* source_frame =
      source_document.AsRenderFrameHostIfValid();
  if (!checking_ || !source_frame ||
      checking_document_.AsRenderFrameHostIfValid() != source_frame) {
    return;
  }
  checking_ = false;
  checking_document_ = content::WeakDocumentPtr();
}

void PhishTabHelper::OnPageSignalsCollected(
    content::WeakDocumentPtr source_document,
    int32_t password_fields,
    int32_t forms,
    const std::vector<std::string>& form_actions,
    const std::string& title,
    const std::string& text_sample) {
  content::RenderFrameHost* source_frame =
      source_document.AsRenderFrameHostIfValid();
  if (!checking_ || !source_frame ||
      checking_document_.AsRenderFrameHostIfValid() != source_frame) {
    return;
  }

  checking_ = false;
  checking_document_ = content::WeakDocumentPtr();
  const GURL current_url = source_frame->GetLastCommittedURL();
  OnPageSignals(std::move(source_document), current_url, password_fields, forms,
                form_actions, title, text_sample);
}

void PhishTabHelper::OnPageSignals(content::WeakDocumentPtr source_document,
                                   const GURL& url,
                                   int32_t password_fields,
                                   int32_t forms,
                                   const std::vector<std::string>& form_actions,
                                   const std::string& title,
                                   const std::string& text_sample) {
  content::WebContents* contents = web_contents();
  if (!contents) {
    return;
  }
  content::RenderFrameHost* source_frame =
      source_document.AsRenderFrameHostIfValid();
  if (!source_frame || source_frame != contents->GetPrimaryMainFrame() ||
      source_frame->IsErrorDocument() ||
      source_frame->GetLastCommittedURL() != url) {
    return;
  }

  AegisService* service = AegisService::GetInstance();
  if (!service->IsPhishInterstitialEnabled()) {
    return;
  }

  int cross_site_form_actions = 0;
  for (const std::string& action_text : form_actions) {
    const GURL action(action_text);
    if (!action.is_valid() || !action.SchemeIsHTTPOrHTTPS() ||
        !action.has_host()) {
      continue;
    }
    if (!net::registry_controlled_domains::SameDomainOrHost(
            url, action,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)) {
      ++cross_site_form_actions;
    }
  }

  PhishAssessment assessment =
      ApplyPageSignals(service->AssessPhishUrl(url),
                       PageSignals{
                           .title = title,
                           .text_sample = text_sample,
                           .password_fields = password_fields,
                           .forms = forms,
                           .cross_site_form_actions = cross_site_form_actions,
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
