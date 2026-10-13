// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_MARKDOWN_UI_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_MARKDOWN_UI_H_
#include "content/public/browser/webui_config.h"
#include "ui/webui/untrusted_web_ui_controller.h"
class AegisMarkdownUI : public ui::UntrustedWebUIController {
 public:
  explicit AegisMarkdownUI(content::WebUI* web_ui);
};
class AegisMarkdownUIConfig
    : public content::DefaultWebUIConfig<AegisMarkdownUI> {
 public:
  AegisMarkdownUIConfig()
      : DefaultWebUIConfig("chrome-untrusted", "aegis-markdown") {}
};
#endif
