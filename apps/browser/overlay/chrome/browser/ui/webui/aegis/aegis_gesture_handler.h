// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_GESTURE_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_GESTURE_HANDLER_H_

#include "content/public/browser/web_ui_message_handler.h"

class AegisGestureHandler : public content::WebUIMessageHandler {
 public:
  AegisGestureHandler();
  ~AegisGestureHandler() override;
  void RegisterMessages() override;

 private:
  bool IsGesturePage();
  void GetSettings(const base::ListValue& args);
  void SaveSettings(const base::ListValue& args);
  void ResetSettings(const base::ListValue& args);
  void SetPracticeRegion(const base::ListValue& args);
  void OnJavascriptDisallowed() override;
  base::DictValue Snapshot();
};
#endif
