// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui_handler.h

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "content/public/browser/web_ui_message_handler.h"

class AegisUIHandler : public content::WebUIMessageHandler {
 public:
  AegisUIHandler();
  AegisUIHandler(const AegisUIHandler&) = delete;
  AegisUIHandler& operator=(const AegisUIHandler&) = delete;
  ~AegisUIHandler() override;

  // content::WebUIMessageHandler:
  void RegisterMessages() override;

 private:
  base::DictValue BuildStatus() const;
  void HandleGetStatus(const base::ListValue& args);
  void HandleSetModuleEnabled(const base::ListValue& args);
  void HandleUpdateFilterLists(const base::ListValue& args);
  void HandleSummarizeActiveTab(const base::ListValue& args);
  void HandleCaptureActiveTab(const base::ListValue& args);
  void HandleOllamaChat(const base::ListValue& args);
  void HandleSetOllamaSettings(const base::ListValue& args);
  void HandleProbeOllama(const base::ListValue& args);
  void OnFilterListsUpdated(std::string callback_id, bool ok);
  void OnPageSignals(std::string callback_id,
                     std::string url,
                     int32_t password_fields,
                     int32_t forms,
                     const std::string& title,
                     const std::string& text_sample);
  void OnCaptured(std::string callback_id,
                  std::string url,
                  int32_t password_fields,
                  int32_t forms,
                  const std::string& title,
                  const std::string& text_sample);
  void OnSummarized(std::string callback_id, aegis::SummarizeResult result);
  void OnOllamaProbed(std::string callback_id,
                      bool ok,
                      std::string error,
                      std::vector<std::string> models);

  base::WeakPtrFactory<AegisUIHandler> weak_factory_{this};
};

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_
