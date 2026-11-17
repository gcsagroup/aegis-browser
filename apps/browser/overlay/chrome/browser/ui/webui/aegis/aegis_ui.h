// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui.h

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_H_

#include "chrome/common/webui_url_constants.h"
#include "content/public/browser/web_ui_controller.h"
#include "content/public/browser/webui_config.h"
#include "content/public/common/url_constants.h"
#include "ui/webui/untrusted_web_ui_controller.h"

namespace content {
class WebUI;
}

class AegisUI;
class AegisCaptureUI;

class AegisCaptureUIConfig : public content::DefaultWebUIConfig<AegisCaptureUI> {
 public:
  AegisCaptureUIConfig();
  bool IsWebUIEnabled(content::BrowserContext* browser_context) override;
};

class AegisCaptureUI : public content::WebUIController {
 public:
  explicit AegisCaptureUI(content::WebUI* web_ui);
  ~AegisCaptureUI() override;

 private:
  WEB_UI_CONTROLLER_TYPE_DECL();
};

class AegisOfflineOCRUI : public ui::UntrustedWebUIController {
 public:
  explicit AegisOfflineOCRUI(content::WebUI* web_ui);
};

class AegisOfflineOCRUIConfig
    : public content::DefaultWebUIConfig<AegisOfflineOCRUI> {
 public:
  AegisOfflineOCRUIConfig();
  bool IsWebUIEnabled(content::BrowserContext* browser_context) override;
};

class AegisUIConfig : public content::DefaultWebUIConfig<AegisUI> {
 public:
  AegisUIConfig()
      : DefaultWebUIConfig(content::kChromeUIScheme,
                           chrome::kChromeUIAegisHost) {}

  bool IsWebUIEnabled(content::BrowserContext* browser_context) override;
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
