// Copyright 2026 GCSA

#include "chrome/browser/page_load_metrics/observers/aegis_miner_guard_page_load_metrics_observer.h"

#include <algorithm>
#include <cmath>

#include "base/functional/bind.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/miner_guard_reporter.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/common/aegis/site_control.h"
#include "components/performance_manager/public/resource_attribution/page_context.h"
#include "components/performance_manager/public/resource_attribution/queries.h"
#include "components/performance_manager/public/resource_attribution/resource_contexts.h"
#include "components/performance_manager/public/resource_attribution/resource_types.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/mojom/use_counter/metrics/web_feature.mojom.h"
#include "third_party/blink/public/mojom/use_counter/use_counter_feature.mojom.h"

namespace aegis {
namespace {

using FeatureType = blink::mojom::UseCounterFeatureType;
using PageContext = resource_attribution::PageContext;
using ResourceType = resource_attribution::ResourceType;
using WebFeature = blink::mojom::WebFeature;

constexpr base::TimeDelta kCpuSampleInterval = base::Seconds(2);
constexpr base::TimeDelta kCpuSampleBackoff = base::Seconds(30);
constexpr int kHighCpuPercent = 35;
constexpr int kMaxCpuPercent = 1000;
constexpr int kMaxSustainedSamples = 10;
constexpr int kMaxCpuSamples = 15;

}  // namespace

AegisMinerGuardPageLoadMetricsObserver::
    AegisMinerGuardPageLoadMetricsObserver() = default;

AegisMinerGuardPageLoadMetricsObserver::
    ~AegisMinerGuardPageLoadMetricsObserver() = default;

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnStart(
    content::NavigationHandle* navigation_handle,
    const GURL& currently_committed_url,
    bool started_in_foreground) {
  if (!navigation_handle->IsInPrimaryMainFrame() ||
      !features::IsMinerGuardGloballyEnabled(true)) {
    return STOP_OBSERVING;
  }
  page_hidden_ = !started_in_foreground;
  signals_.background = page_hidden_;
  return CONTINUE_OBSERVING;
}

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnCommit(
    content::NavigationHandle* navigation_handle) {
  if (!navigation_handle->IsInPrimaryMainFrame() ||
      !navigation_handle->GetURL().SchemeIsHTTPOrHTTPS()) {
    return STOP_OBSERVING;
  }
  content::RenderFrameHost* frame = navigation_handle->GetRenderFrameHost();
  if (!frame) {
    return STOP_OBSERVING;
  }
  display_domain_ = std::string(navigation_handle->GetURL().host());
  site_key_ = SiteKeyForHost(display_domain_);
  document_id_ = frame->GetReportingSource().ToString();
  return CONTINUE_OBSERVING;
}

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnFencedFramesStart(
    content::NavigationHandle* navigation_handle,
    const GURL& currently_committed_url) {
  return STOP_OBSERVING;
}

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnPrerenderStart(
    content::NavigationHandle* navigation_handle,
    const GURL& currently_committed_url) {
  return STOP_OBSERVING;
}

void AegisMinerGuardPageLoadMetricsObserver::OnFeaturesUsageObserved(
    content::RenderFrameHost* rfh,
    const std::vector<blink::UseCounterFeature>& features) {
  if (!IsEnabledForCurrentPage()) {
    StopCpuSampling();
    return;
  }
  MinerRuntimeSignals report;
  bool changed = false;
  const auto observe = [&changed](bool* current, bool* outgoing) {
    if (*current) {
      return;
    }
    *current = true;
    *outgoing = true;
    changed = true;
  };
  for (const blink::UseCounterFeature& feature : features) {
    if (feature.type() != FeatureType::kWebFeature) {
      continue;
    }
    switch (static_cast<WebFeature>(feature.value())) {
      case WebFeature::kWorkerStart:
        observe(&signals_.worker, &report.worker);
        break;
      case WebFeature::kWebAssemblyInstantiation:
      case WebFeature::kWebAssemblyModuleCompilation:
        observe(&signals_.wasm, &report.wasm);
        break;
      case WebFeature::kWebGPURequestAdapter:
      case WebFeature::kWebGPUQueueSubmit:
        observe(&signals_.webgpu, &report.webgpu);
        break;
      case WebFeature::kV8SharedArrayBufferConstructed:
      case WebFeature::kUnrestrictedSharedArrayBuffer:
        observe(&signals_.shared_memory, &report.shared_memory);
        break;
      case WebFeature::kWebSocket:
        observe(&signals_.websocket, &report.websocket);
        break;
      default:
        break;
    }
  }
  if (!changed) {
    return;
  }
  report.background = page_hidden_;
  ReportSignals(report);
  MaybeStartCpuSampling();
}

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnHidden(
    const page_load_metrics::mojom::PageLoadTiming& timing) {
  if (page_hidden_) {
    return CONTINUE_OBSERVING;
  }
  page_hidden_ = true;
  signals_.background = true;
  MinerRuntimeSignals report;
  report.background = true;
  ReportSignals(report);
  return CONTINUE_OBSERVING;
}

page_load_metrics::PageLoadMetricsObserver::ObservePolicy
AegisMinerGuardPageLoadMetricsObserver::OnShown() {
  page_hidden_ = false;
  signals_.background = false;
  return CONTINUE_OBSERVING;
}

void AegisMinerGuardPageLoadMetricsObserver::OnComplete(
    const page_load_metrics::mojom::PageLoadTiming& timing) {
  StopCpuSampling();
}

bool AegisMinerGuardPageLoadMetricsObserver::IsEnabledForCurrentPage() const {
  if (!features::IsMinerGuardGloballyEnabled(true)) {
    return false;
  }
  content::WebContents* web_contents = GetDelegate().GetWebContents();
  if (!web_contents || site_key_.empty()) {
    return false;
  }
  Profile* profile =
      Profile::FromBrowserContext(web_contents->GetBrowserContext());
  PrefService* prefs = profile ? profile->GetPrefs() : nullptr;
  if (!prefs || !prefs->GetBoolean(prefs::kMinerGuardEnabled)) {
    return false;
  }
  return !IsSitePaused(
      prefs->GetString(prefs::kPausedSites), site_key_,
      (base::Time::Now() - base::Time::UnixEpoch()).InSeconds());
}

void AegisMinerGuardPageLoadMetricsObserver::MaybeStartCpuSampling() {
  if (!IsEnabledForCurrentPage()) {
    StopCpuSampling();
    return;
  }
  if (!ShouldSampleMinerCpu(signals_) || cpu_timer_.IsRunning() ||
      cpu_backoff_timer_.IsRunning()) {
    return;
  }
  cpu_sample_count_ = 0;
  SampleCpu();
  cpu_timer_.Start(
      FROM_HERE, kCpuSampleInterval,
      base::BindRepeating(&AegisMinerGuardPageLoadMetricsObserver::SampleCpu,
                          weak_ptr_factory_.GetWeakPtr()));
}

void AegisMinerGuardPageLoadMetricsObserver::StopCpuSampling() {
  cpu_timer_.Stop();
  cpu_backoff_timer_.Stop();
}

void AegisMinerGuardPageLoadMetricsObserver::SampleCpu() {
  if (cpu_query_in_flight_) {
    return;
  }
  if (cpu_sample_count_ >= kMaxCpuSamples) {
    cpu_timer_.Stop();
    signals_.sustained_high_cpu_samples = 0;
    previous_measurement_time_.reset();
    cpu_backoff_timer_.Start(
        FROM_HERE, kCpuSampleBackoff,
        base::BindOnce(
            &AegisMinerGuardPageLoadMetricsObserver::MaybeStartCpuSampling,
            weak_ptr_factory_.GetWeakPtr()));
    return;
  }
  if (!IsEnabledForCurrentPage()) {
    StopCpuSampling();
    return;
  }
  content::WebContents* web_contents = GetDelegate().GetWebContents();
  std::optional<PageContext> page_context =
      PageContext::FromWebContents(web_contents);
  if (!page_context) {
    return;
  }
  ++cpu_sample_count_;
  cpu_query_in_flight_ = true;
  resource_attribution::QueryBuilder()
      .AddResourceType(ResourceType::kCPUTime)
      .AddResourceContext(*page_context)
      .QueryOnce(
          base::BindOnce(&AegisMinerGuardPageLoadMetricsObserver::OnCpuSample,
                         weak_ptr_factory_.GetWeakPtr()));
}

void AegisMinerGuardPageLoadMetricsObserver::OnCpuSample(
    const resource_attribution::QueryResultMap& query_results) {
  cpu_query_in_flight_ = false;
  if (query_results.empty() || !IsEnabledForCurrentPage()) {
    return;
  }
  const auto& cpu_result = query_results.begin()->second.cpu_time_result;
  if (!cpu_result) {
    return;
  }
  const base::TimeTicks measurement_time =
      cpu_result->metadata.measurement_time;
  if (!previous_measurement_time_) {
    previous_measurement_time_ = measurement_time;
    previous_cpu_ = cpu_result->cumulative_cpu;
    previous_background_cpu_ = cpu_result->cumulative_background_cpu;
    return;
  }
  const base::TimeDelta wall_time =
      measurement_time - *previous_measurement_time_;
  const base::TimeDelta cpu_delta = cpu_result->cumulative_cpu - previous_cpu_;
  const base::TimeDelta background_delta =
      cpu_result->cumulative_background_cpu - previous_background_cpu_;
  previous_measurement_time_ = measurement_time;
  previous_cpu_ = cpu_result->cumulative_cpu;
  previous_background_cpu_ = cpu_result->cumulative_background_cpu;
  if (!wall_time.is_positive() || cpu_delta.is_negative()) {
    return;
  }
  const double cpu_percent =
      100.0 * cpu_delta.InMicrosecondsF() / wall_time.InMicrosecondsF();
  signals_.cpu_percent =
      std::clamp(static_cast<int>(std::lround(cpu_percent)), 0, kMaxCpuPercent);
  if (signals_.cpu_percent >= kHighCpuPercent) {
    signals_.sustained_high_cpu_samples =
        std::min(kMaxSustainedSamples, signals_.sustained_high_cpu_samples + 1);
  } else {
    signals_.sustained_high_cpu_samples = 0;
  }
  signals_.background = page_hidden_ || background_delta.is_positive();
  MinerRuntimeSignals report;
  report.cpu_sampled = true;
  report.cpu_percent = signals_.cpu_percent;
  report.sustained_high_cpu_samples = signals_.sustained_high_cpu_samples;
  report.background = signals_.background;
  report.worker = signals_.worker;
  report.wasm = signals_.wasm;
  report.webgpu = signals_.webgpu;
  report.shared_memory = signals_.shared_memory;
  report.websocket = signals_.websocket;
  ReportSignals(report);
}

void AegisMinerGuardPageLoadMetricsObserver::ReportSignals(
    const MinerRuntimeSignals& report) {
  if (document_id_.empty() || site_key_.empty() || !IsEnabledForCurrentPage()) {
    return;
  }
  MinerGuardReporter::ReportSignals(document_id_, site_key_, display_domain_,
                                    report);
}

}  // namespace aegis
