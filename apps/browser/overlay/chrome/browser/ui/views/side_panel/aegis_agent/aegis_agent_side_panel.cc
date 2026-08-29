// Copyright 2026 GCSA

#include "chrome/browser/ui/views/side_panel/aegis_agent/aegis_agent_side_panel.h"

#include <memory>

#include "base/feature_list.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/side_panel/side_panel_entry.h"
#include "chrome/browser/ui/side_panel/side_panel_registry.h"
#include "chrome/browser/ui/side_panel/side_panel_ui.h"
#include "chrome/browser/ui/views/side_panel/side_panel_web_ui_view.h"
#include "chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.h"
#include "chrome/browser/ui/webui/top_chrome/webui_contents_wrapper.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/webui_url_constants.h"
#include "chrome/grit/branded_strings.h"
#include "ui/base/metadata/metadata_impl_macros.h"

using SidePanelWebUIViewT_AegisAgentUI = SidePanelWebUIViewT<AegisAgentUI>;
BEGIN_TEMPLATE_METADATA(SidePanelWebUIViewT_AegisAgentUI, SidePanelWebUIViewT)
END_METADATA

namespace aegis::agent {
namespace {

std::unique_ptr<views::View> CreateAgentView(BrowserWindowInterface* browser,
                                             SidePanelEntryScope& scope) {
  return std::make_unique<SidePanelWebUIViewT<AegisAgentUI>>(
      scope, base::RepeatingClosure(), base::RepeatingClosure(),
      std::make_unique<WebUIContentsWrapperT<AegisAgentUI>>(
          GURL(chrome::kChromeUIUntrustedAegisAgentURL), browser->GetProfile(),
          IDS_PRODUCT_NAME, /*esc_closes_ui=*/false));
}

}  // namespace

bool IsAegisAgentSidePanelSupported(Profile* profile) {
  return profile && profile->IsRegularProfile() &&
         base::FeatureList::IsEnabled(aegis::features::kAegisAgent);
}

void RegisterAegisAgentSidePanel(BrowserWindowInterface* browser,
                                 SidePanelRegistry* registry) {
  if (!browser || !registry ||
      !IsAegisAgentSidePanelSupported(browser->GetProfile())) {
    return;
  }
  registry->Register(std::make_unique<SidePanelEntry>(
      SidePanelEntry::Key(SidePanelEntry::Id::kAegisAgent),
      base::BindRepeating(&CreateAgentView, base::Unretained(browser)),
      /*default_content_width_callback=*/base::NullCallback()));
}

bool ShowAegisAgentSidePanel(BrowserWindowInterface* browser) {
  if (!browser || !IsAegisAgentSidePanelSupported(browser->GetProfile())) {
    return false;
  }
  SidePanelUI* side_panel = browser->GetFeatures().side_panel_ui();
  if (!side_panel) {
    return false;
  }
  side_panel->Show(SidePanelEntry::Id::kAegisAgent);
  return true;
}

}  // namespace aegis::agent
