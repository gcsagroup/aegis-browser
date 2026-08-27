// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_PAGE_LOAD_METRICS_OBSERVERS_AEGIS_MINER_GUARD_PAGE_LOAD_METRICS_OBSERVER_H_
#define CHROME_BROWSER_PAGE_LOAD_METRICS_OBSERVERS_AEGIS_MINER_GUARD_PAGE_LOAD_METRICS_OBSERVER_H_

#include <optional>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "chrome/common/aegis/miner_guard_model.h"
#include "components/page_load_metrics/browser/page_load_metrics_observer.h"
#include "components/performance_manager/public/resource_attribution/query_results.h"

namespace content {
class NavigationHandle;
class RenderFrameHost;
}  // namespace content

namespace aegis {

// Trusted browser-side observation only. This class never executes page source,
// blocks a request or terminates a worker.
class AegisMinerGuardPageLoadMetricsObserver
    : public page_load_metrics::PageLoadMetricsObserver {
 public:
  AegisMinerGuardPageLoadMetricsObserver();
  ~AegisMinerGuardPageLoadMetricsObserver() override;

  AegisMinerGuardPageLoadMetricsObserver(
      const AegisMinerGuardPageLoadMetricsObserver&) = delete;
  AegisMinerGuardPageLoadMetricsObserver& operator=(
      const AegisMinerGuardPageLoadMetricsObserver&) = delete;

  ObservePolicy OnStart(content::NavigationHandle* navigation_handle,
                        const GURL& currently_committed_url,
                        bool started_in_foreground) override;
  ObservePolicy OnCommit(content::NavigationHandle* navigation_handle) override;
  ObservePolicy OnFencedFramesStart(
      content::NavigationHandle* navigation_handle,
      const GURL& currently_committed_url) override;
  ObservePolicy OnPrerenderStart(content::NavigationHandle* navigation_handle,
                                 const GURL& currently_committed_url) override;
  void OnFeaturesUsageObserved(
      content::RenderFrameHost* rfh,
      const std::vector<blink::UseCounterFeature>& features) override;
  ObservePolicy OnHidden(
      const page_load_metrics::mojom::PageLoadTiming& timing) override;
  ObservePolicy OnShown() override;
  void OnComplete(
      const page_load_metrics::mojom::PageLoadTiming& timing) override;

 private:
  bool IsEnabledForCurrentPage() const;
  void MaybeStartCpuSampling();
  void StopCpuSampling();
  void SampleCpu();
  void OnCpuSample(const resource_attribution::QueryResultMap& query_results);
  void ReportSignals(const MinerRuntimeSignals& report);

  MinerRuntimeSignals signals_;
  std::string document_id_;
  std::string site_key_;
  std::string display_domain_;
  bool page_hidden_ = false;
  int cpu_sample_count_ = 0;
  bool cpu_query_in_flight_ = false;
  std::optional<base::TimeTicks> previous_measurement_time_;
  base::TimeDelta previous_cpu_;
  base::TimeDelta previous_background_cpu_;
  base::RepeatingTimer cpu_timer_;
  base::OneShotTimer cpu_backoff_timer_;
  base::WeakPtrFactory<AegisMinerGuardPageLoadMetricsObserver>
      weak_ptr_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_PAGE_LOAD_METRICS_OBSERVERS_AEGIS_MINER_GUARD_PAGE_LOAD_METRICS_OBSERVER_H_
