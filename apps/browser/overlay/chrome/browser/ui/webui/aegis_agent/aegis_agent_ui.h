// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_UI_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_UI_H_

#include <memory>

#include "chrome/browser/ui/webui/aegis_agent/aegis_agent.mojom.h"
#include "chrome/browser/ui/webui/top_chrome/top_chrome_webui_config.h"
#include "chrome/browser/ui/webui/top_chrome/untrusted_top_chrome_web_ui_controller.h"
#include "mojo/public/cpp/bindings/receiver.h"

class AegisAgentPageHandler;

class AegisAgentUI;

class AegisAgentUIConfig : public DefaultTopChromeWebUIConfig<AegisAgentUI> {
 public:
  AegisAgentUIConfig();
  ~AegisAgentUIConfig() override;

  bool IsWebUIEnabled(content::BrowserContext* browser_context) override;
};

class AegisAgentUI : public UntrustedTopChromeWebUIController,
                     public aegis_agent::mojom::PageHandlerFactory {
 public:
  explicit AegisAgentUI(content::WebUI* web_ui);
  ~AegisAgentUI() override;

  void BindInterface(
      mojo::PendingReceiver<aegis_agent::mojom::PageHandlerFactory> receiver);

  static constexpr std::string_view GetWebUIName() { return "AegisAgent"; }

 private:
  void CreatePageHandler(
      mojo::PendingRemote<aegis_agent::mojom::Page> page,
      mojo::PendingReceiver<aegis_agent::mojom::PageHandler> receiver) override;

  std::unique_ptr<AegisAgentPageHandler> page_handler_;
  mojo::Receiver<aegis_agent::mojom::PageHandlerFactory> page_factory_receiver_{
      this};

  WEB_UI_CONTROLLER_TYPE_DECL();
};

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AGENT_AEGIS_AGENT_UI_H_
