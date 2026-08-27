// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_THREAT_FEED_UPDATER_H_
#define CHROME_BROWSER_AEGIS_THREAT_FEED_UPDATER_H_

#include <cstdint>
#include <memory>
#include <optional>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "chrome/common/aegis/threat_feed_index.h"

class GURL;
class Profile;

namespace network {
class SimpleURLLoader;
}

namespace aegis {

// Loads an immutable local multi-source reputation index and refreshes the
// public CERT.PL domain source in the background. PhishTank and URLhaus are
// imported by the offline compiler because their production feeds require
// larger downloads or credentials that must not be embedded in Chromium.
class ThreatFeedUpdater {
 public:
  explicit ThreatFeedUpdater(Profile* profile);
  ThreatFeedUpdater(const ThreatFeedUpdater&) = delete;
  ThreatFeedUpdater& operator=(const ThreatFeedUpdater&) = delete;
  ~ThreatFeedUpdater();

  void LoadFromDisk();
  std::optional<ThreatMatch> Match(const GURL& url, int64_t now) const;

 private:
  void OnLoadedFromDisk(std::optional<ThreatIndex> index);
  void MaybeUpdate();
  void UpdateNow();
  void OnFetched(std::optional<std::string> body);
  void OnCompiled(std::optional<ThreatIndex> index);
  void Persist(const ThreatIndex& index);
  void Schedule(base::TimeDelta delay);

  raw_ptr<Profile> profile_;
  std::optional<ThreatIndex> index_;
  bool updating_ = false;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer timer_;
  base::WeakPtrFactory<ThreatFeedUpdater> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_THREAT_FEED_UPDATER_H_
