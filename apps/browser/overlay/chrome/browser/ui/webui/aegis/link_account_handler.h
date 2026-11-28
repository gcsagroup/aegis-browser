// 只向当前普通 Profile 的原生账号页提供固定门户会话、同步集合和本地资料读写。
#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_ACCOUNT_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_LINK_ACCOUNT_HANDLER_H_
#include <memory>
#include <optional>
#include <string>
#include "base/memory/weak_ptr.h"
#include "content/public/browser/web_ui_message_handler.h"
namespace network {
class SimpleURLLoader;
}
class LinkAccountHandler : public content::WebUIMessageHandler {
 public:
  LinkAccountHandler();
  ~LinkAccountHandler() override;
  void RegisterMessages() override;

 private:
  void OnJavascriptDisallowed() override;
  void Dispatch(const base::ListValue& args);
  void Fetch(std::string callback,
             std::string action,
             std::string path,
             const base::DictValue& input);
  void Received(std::string callback,
                std::string action,
                std::optional<std::string> body);
  std::unique_ptr<network::SimpleURLLoader> request_;
  std::string user_id_;
  std::string csrf_;
  base::WeakPtrFactory<LinkAccountHandler> weak_{this};
};
#endif
