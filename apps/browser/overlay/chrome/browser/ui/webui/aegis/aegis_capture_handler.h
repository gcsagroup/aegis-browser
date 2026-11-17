// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_CAPTURE_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_CAPTURE_HANDLER_H_

#include <memory>
#include <optional>
#include <string>

#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "content/public/browser/web_ui_message_handler.h"

class PrefService;

namespace network {
class SimpleURLLoader;
}

namespace aegis {

base::DictValue ReadImageOcrSettings(const PrefService& prefs);
bool SaveImageOcrSettings(PrefService& prefs,
                          const std::string& mode,
                          const std::string& endpoint);

class CaptureHandler : public content::WebUIMessageHandler {
 public:
  CaptureHandler();
  ~CaptureHandler() override;
  void RegisterMessages() override;
  void OnJavascriptDisallowed() override;

 private:
  void TakeImage(const base::ListValue& args);
  void GetRemoteDestination(const base::ListValue& args);
  void PrepareRemoteRequest(const base::ListValue& args);
  void RecognizeLocally(const base::ListValue& args);
  void RecognizeRemotely(const base::ListValue& args);
  void LocalReply(std::string callback, std::string text);
  void RemoteReply(std::string callback, std::optional<std::string> body);
  bool IsCapturePage();

  bool ocr_ = false;
  bool local_started_ = false;
  std::string prepared_endpoint_;
  std::unique_ptr<network::SimpleURLLoader> request_;
  base::WeakPtrFactory<CaptureHandler> weak_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_CAPTURE_HANDLER_H_
