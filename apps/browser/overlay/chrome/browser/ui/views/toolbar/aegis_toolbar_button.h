// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_UI_VIEWS_TOOLBAR_AEGIS_TOOLBAR_BUTTON_H_
#define CHROME_BROWSER_UI_VIEWS_TOOLBAR_AEGIS_TOOLBAR_BUTTON_H_

#include "base/memory/raw_ptr.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/ui/views/toolbar/toolbar_button.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/views/view_tracker.h"

class Browser;

namespace content {
class WebContents;
}

// Browser-native Aegis entry point. It intentionally lives in the toolbar
// instead of a page injection or extension surface.
class AegisToolbarButton : public ToolbarButton,
                           public aegis::AegisServiceObserver {
  METADATA_HEADER(AegisToolbarButton, ToolbarButton)

 public:
  explicit AegisToolbarButton(Browser* browser);
  AegisToolbarButton(const AegisToolbarButton&) = delete;
  AegisToolbarButton& operator=(const AegisToolbarButton&) = delete;
  ~AegisToolbarButton() override;

  void Update(content::WebContents* web_contents);

  // aegis::AegisServiceObserver:
  void OnAegisStateChanged() override;

 private:
  void OnPressed();
  void Refresh();
  void ClearIntroHighlight();

  const raw_ptr<Browser> browser_;
  raw_ptr<content::WebContents> web_contents_ = nullptr;
  bool observing_service_ = false;
  views::ViewTracker bubble_tracker_;
  base::OneShotTimer intro_timer_;
};

#endif  // CHROME_BROWSER_UI_VIEWS_TOOLBAR_AEGIS_TOOLBAR_BUTTON_H_
