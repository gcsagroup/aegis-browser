// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_ENHANCEMENT_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_ENHANCEMENT_HANDLER_H_
#include <memory>
#include "base/memory/weak_ptr.h"
#include "chrome/browser/aegis/model_provider_client.h"
#include "content/public/browser/web_ui_message_handler.h"
class AegisReadingWorkspace;
class AegisEnhancementHandler : public content::WebUIMessageHandler {
 public:
  AegisEnhancementHandler();
  ~AegisEnhancementHandler() override;
  void RegisterMessages() override;

 private:
  void Request(const base::ListValue& args);
  void Reply(base::Value callback, base::DictValue result);
  void OnJavascriptDisallowed() override;
  base::DictValue Snapshot();
  std::unique_ptr<aegis::ModelProviderClient> model_;
  std::unique_ptr<AegisReadingWorkspace> reading_;
  base::WeakPtrFactory<AegisEnhancementHandler> weak_{this};
};
#endif
