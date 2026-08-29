// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_UI_VIEWS_SIDE_PANEL_AEGIS_AGENT_AEGIS_AGENT_SIDE_PANEL_H_
#define CHROME_BROWSER_UI_VIEWS_SIDE_PANEL_AEGIS_AGENT_AEGIS_AGENT_SIDE_PANEL_H_

class BrowserWindowInterface;
class Profile;
class SidePanelRegistry;

namespace aegis::agent {

bool IsAegisAgentSidePanelSupported(Profile* profile);
void RegisterAegisAgentSidePanel(BrowserWindowInterface* browser,
                                 SidePanelRegistry* registry);
bool ShowAegisAgentSidePanel(BrowserWindowInterface* browser);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_UI_VIEWS_SIDE_PANEL_AEGIS_AGENT_AEGIS_AGENT_SIDE_PANEL_H_
