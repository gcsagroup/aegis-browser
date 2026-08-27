// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui.h

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_H_

#include "chrome/common/webui_url_constants.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"
#include "content/public/common/url_constants.h"

namespace content {
class WebUI;
}

class AegisUI;

class AegisUIConfig : public content::DefaultWebUIConfig<AegisUI> {
 public:
  AegisUIConfig()
      : DefaultWebUIConfig(content::kChromeUIScheme,
                           chrome::kChromeUIAegisHost) {}
};

// chrome://aegis — GCSA-aegis module status and toggles.
class AegisUI : public content::WebUIController {
 public:
  explicit AegisUI(content::WebUI* web_ui);
  ~AegisUI() override;
  AegisUI(const AegisUI&) = delete;
  AegisUI& operator=(const AegisUI&) = delete;

 private:
  WEB_UI_CONTROLLER_TYPE_DECL();
};

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_H_
