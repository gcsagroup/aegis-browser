// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_REFRESH_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_REFRESH_H_

#include <optional>
#include <set>
#include <string>
#include <string_view>

#include "base/time/time.h"
#include "base/unguessable_token.h"

namespace aegis::access {

// Presentation shared with Settings' binary units and exact byte counts.
std::u16string FormatAccessUsageBytes(std::string_view raw);

// Profile-owned schedule, shared by every quota surface. Only a completed
// request starts the next interval. Backgrounding never cancels a request or
// permits a second one; late completion cannot restart a background timer.
class AccessAccountRefresh {
 public:
  AccessAccountRefresh();
  ~AccessAccountRefresh();

  void SetActivity(bool app_foreground, bool profile_focused,
                   base::TimeTicks now) {
    app_foreground_ = app_foreground;
    profile_focused_ = profile_focused;
    UpdateActivity(now);
  }

  void SetVisible(base::UnguessableToken owner, bool visible,
                  base::TimeTicks now) {
    const bool was_visible = !owners_.empty();
    if (visible) owners_.insert(owner);
    else owners_.erase(owner);
    UpdateActivity(now);
    if (was_visible == !owners_.empty() || failures_ || in_flight_) return;
    next_ = owners_.empty() ? now + base::Seconds(30) : now;
  }

  bool Begin(base::TimeTicks now, bool manual = false) {
    if (!active_) return false;
    if (manual) {
      if (last_manual_ && now - *last_manual_ < base::Seconds(1)) return false;
      last_manual_ = now;
    }
    if (in_flight_ || (!manual && now < next_)) return false;
    in_flight_ = true;
    return true;
  }

  void Complete(bool succeeded, base::TimeTicks now) {
    in_flight_ = false;
    const bool refresh_on_resume = refresh_after_current_;
    refresh_after_current_ = false;
    failures_ = succeeded ? 0 : (failures_ == 0 ? 1 : 2);
    if (refresh_on_resume) {
      next_ = now;
      return;
    }
    next_ = now + (failures_ == 1 ? base::Seconds(15)
        : failures_ == 2 ? base::Seconds(30)
        : owners_.empty() ? base::Seconds(30) : base::Seconds(5));
  }

  std::optional<base::TimeDelta> DueIn(base::TimeTicks now) const {
    if (!active_ || in_flight_) return std::nullopt;
    return next_ > now ? next_ - now : base::TimeDelta();
  }

  bool in_flight() const { return in_flight_; }

  void IdentityChanged(base::TimeTicks now) {
    failures_ = 0;
    last_manual_.reset();
    next_ = now;
  }

 private:
  void UpdateActivity(base::TimeTicks now) {
    const bool active = app_foreground_ && (profile_focused_ || !owners_.empty());
    if (active_ == active) return;
    active_ = active;
    refresh_after_current_ = active && in_flight_;
    if (active) next_ = now;
  }

  bool app_foreground_ = false;
  bool profile_focused_ = false;
  bool active_ = false;
  bool in_flight_ = false;
  bool refresh_after_current_ = false;
  int failures_ = 0;
  std::set<base::UnguessableToken> owners_;
  std::optional<base::TimeTicks> last_manual_;
  base::TimeTicks next_;
};

}  // namespace aegis::access
#endif
