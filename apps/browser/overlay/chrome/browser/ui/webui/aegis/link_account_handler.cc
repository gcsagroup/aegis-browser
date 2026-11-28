// 账号页的浏览器进程桥接。只向打包来源的三个固定接口发送当前 Profile
// 的第一方会话。
#include "chrome/browser/ui/webui/aegis/link_account_handler.h"

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/webui/aegis/link_first_run_choice.h"
#include "chrome/browser/ui/webui/aegis/link_portal_origin.h"
#include "chrome/browser/ui/webui/aegis/link_profile_data.h"
#include "chrome/common/aegis/link_account.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "content/public/browser/web_ui.h"
#include "net/base/isolation_info.h"
#include "net/base/load_flags.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/origin.h"

namespace {
GURL Portal() {
  return GURL(AEGIS_LINK_PORTAL_ORIGIN);
}

// 只有从原生登录按钮开始的本次标签页导航可以返回账号页。普通网页不能发起特权导航。
class LoginReturn : public content::WebContentsObserver,
                    public content::WebContentsUserData<LoginReturn> {
 public:
  void Begin() {
    waiting_ = true;
    web_contents()->GetController().LoadURL(
        Portal().Resolve("/login?next=/account"), content::Referrer(),
        ui::PAGE_TRANSITION_AUTO_BOOKMARK, {});
  }
  void DidFinishNavigation(content::NavigationHandle* nav) override {
    if (!waiting_ || !nav->IsInPrimaryMainFrame() || !nav->HasCommitted() ||
        nav->IsErrorPage())
      return;
    if (nav->GetURL() != Portal().Resolve("/account"))
      return;
    waiting_ = false;
    // 同文档 SPA 登录回跳也会到这里。延迟导航避免在提交回调内重入。
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(
                       [](base::WeakPtr<content::WebContents> tab) {
                         if (tab && tab->GetLastCommittedURL() ==
                                        Portal().Resolve("/account"))
                           tab->GetController().LoadURL(
                               GURL(aegis::link::FirstRunChoice::From(tab.get())
                                        ? aegis::link::kWelcomePage
                                        : aegis::link::kPage),
                               content::Referrer(),
                               ui::PAGE_TRANSITION_AUTO_BOOKMARK, {});
                       },
                       web_contents()->GetWeakPtr()));
  }

 private:
  friend class content::WebContentsUserData<LoginReturn>;
  explicit LoginReturn(content::WebContents* tab)
      : content::WebContentsObserver(tab),
        content::WebContentsUserData<LoginReturn>(*tab) {}
  bool waiting_ = false;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
WEB_CONTENTS_USER_DATA_KEY_IMPL(LoginReturn);

std::string Field(const base::DictValue& dict, std::string_view key) {
  const auto* value = dict.FindString(key);
  return value ? *value : std::string();
}
}  // namespace

LinkAccountHandler::LinkAccountHandler() = default;
LinkAccountHandler::~LinkAccountHandler() = default;
void LinkAccountHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "aegisLinkAccount", base::BindRepeating(&LinkAccountHandler::Dispatch,
                                              base::Unretained(this)));
}
void LinkAccountHandler::OnJavascriptDisallowed() {
  weak_.InvalidateWeakPtrs();
  request_.reset();
  csrf_.clear();
  user_id_.clear();
}
void LinkAccountHandler::Dispatch(const base::ListValue& args) {
  auto* contents = web_ui()->GetWebContents();
  Profile* profile = Profile::FromWebUI(web_ui());
  if (!profile->IsRegularProfile() || profile->IsOffTheRecord() ||
      contents->GetLastCommittedURL().GetWithoutRef() !=
          GURL(aegis::link::kPage) ||
      args.size() != 3 || !args[0].is_string() || !args[1].is_string() ||
      !args[2].is_dict())
    return;
  AllowJavascript();
  const auto& callback = args[0];
  const auto& action = args[1].GetString();
  const auto& input = args[2].GetDict();
  if (action == "isWelcomeWindow") {
    // 标签页即使打开相同 URL，也只能看到普通账号管理界面。
    ResolveJavascriptCallback(callback, base::Value(
        aegis::link::FirstRunChoice::From(contents) != nullptr));
    return;
  }
  if (action == "login" || action == "skip") {
    ResolveJavascriptCallback(callback, base::Value(true));
    if (action == "login") {
      LoginReturn::CreateForWebContents(contents);
      LoginReturn::FromWebContents(contents)->Begin();
    } else if (auto* decision = aegis::link::FirstRunChoice::From(contents)) {
      decision->Complete();
    }
    return;
  }
  if (request_) {
    RejectJavascriptCallback(callback, base::Value("busy"));
    return;
  }
  if (action == "session") {
    Fetch(callback.GetString(), action, "/api/v1/auth/session", input);
    return;
  }
  if (action == "logout" && !user_id_.empty() && !csrf_.empty()) {
    Fetch(callback.GetString(), action, "/api/v1/auth/logout", input);
    return;
  }
  const auto kind = Field(input, "collection");
  if (user_id_.empty() || Field(input, "account") != user_id_ ||
      (kind != "preferences" && kind != "bookmarks")) {
    RejectJavascriptCallback(callback, base::Value("account"));
    return;
  }
  if (action == "profile") {
    auto data = aegis::link::ProfileData(
        profile, Portal().spec() + user_id_,
        profile->GetPrefs()->GetString(aegis::link::kEmail), kind, input);
    if (data.has_value())
      ResolveJavascriptCallback(callback, *data);
    else
      RejectJavascriptCallback(callback, base::Value(data.error()));
  } else if (action == "read" || action == "write") {
    Fetch(callback.GetString(), action, "/api/v1/me/browser-sync/" + kind,
          input);
  } else {
    RejectJavascriptCallback(callback, base::Value("invalid"));
  }
}

void LinkAccountHandler::Fetch(std::string callback,
                               std::string action,
                               std::string path,
                               const base::DictValue& input) {
  auto request = std::make_unique<network::ResourceRequest>();
  const auto origin = url::Origin::Create(Portal());
  request->url = Portal().Resolve(path);
  request->credentials_mode = network::mojom::CredentialsMode::kInclude;
  request->redirect_mode = network::mojom::RedirectMode::kError;
  request->load_flags = net::LOAD_DISABLE_CACHE;
  request->site_for_cookies = net::SiteForCookies::FromOrigin(origin);
  request->request_initiator = origin;
  request->trusted_params.emplace();
  request->trusted_params->isolation_info =
      net::IsolationInfo::CreateForInternalRequest(origin);
  std::string payload;
  if (action != "session")
    request->headers.SetHeader("X-Aegis-Browser-Account", user_id_);
  if (action == "write") {
    auto* change = input.FindDict("change");
    if (!change || csrf_.empty() ||
        !base::JSONWriter::Write(*change, &payload) ||
        payload.size() > 3 * 1024 * 1024) {
      RejectJavascriptCallback(base::Value(callback), base::Value("invalid"));
      return;
    }
    request->method = "PUT";
    request->headers.SetHeader("Origin", origin.Serialize());
    request->headers.SetHeader("X-CSRF-Token", csrf_);
  }
  if (action == "logout") {
    request->method = "POST";
    request->headers.SetHeader("Origin", origin.Serialize());
    request->headers.SetHeader("X-CSRF-Token", csrf_);
    payload = "{}";
  }
  constexpr auto annotation =
      net::DefineNetworkTrafficAnnotation("aegis_profile_account", R"(
    semantics { sender: "Aegis Browser Account" description: "Check the portal session or sync encrypted profile data."
      trigger: "User opens the account page or requests sync." data: "First-party session or encrypted collection."
      destination: OTHER destination_other: "The Aegis Link portal selected at build time." }
    policy { cookies_allowed: YES cookies_store: "Current regular profile"
      setting: "Sync is optional and initiated from the browser account page." policy_exception_justification: "User-initiated action." })");
  request_ = network::SimpleURLLoader::Create(std::move(request), annotation);
  request_->SetTimeoutDuration(base::Seconds(15));
  request_->SetAllowHttpErrorResults(true);
  if (!payload.empty())
    request_->AttachStringForUpload(payload, "application/json");
  request_->DownloadToString(
      Profile::FromWebUI(web_ui())
          ->GetDefaultStoragePartition()
          ->GetURLLoaderFactoryForBrowserProcess()
          .get(),
      base::BindOnce(&LinkAccountHandler::Received, weak_.GetWeakPtr(),
                     std::move(callback), std::move(action)),
      3 * 1024 * 1024);
}

void LinkAccountHandler::Received(std::string callback,
                                  std::string action,
                                  std::optional<std::string> body) {
  auto loader = std::move(request_);
  const auto* info = loader->ResponseInfo();
  const int status = info && info->headers ? info->headers->response_code() : 0;
  auto* prefs = Profile::FromWebUI(web_ui())->GetPrefs();
  const base::Value id(callback);
  if (status == 401 || status == 403) {
    user_id_.clear();
    csrf_.clear();
    prefs->ClearPref(aegis::link::kEmail);
    RejectJavascriptCallback(id, base::Value("signin"));
    return;
  }
  if (action == "logout" && status == 200) {
    user_id_.clear();
    csrf_.clear();
    prefs->ClearPref(aegis::link::kEmail);
    ResolveJavascriptCallback(id, base::Value(true));
    return;
  }
  if (status == 409) {
    RejectJavascriptCallback(id, base::Value("conflict"));
    return;
  }
  auto json = body && status == 200
                  ? base::JSONReader::ReadDict(*body, base::JSON_PARSE_RFC)
                  : std::nullopt;
  auto* data = json ? json->FindDict("data") : nullptr;
  if (!data) {
    RejectJavascriptCallback(id, base::Value("network"));
    return;
  }
  if (action == "session") {
    const auto* principal = data->FindDict("principal");
    if (!principal || Field(*principal, "kind") != "user" ||
        Field(*principal, "id").empty() || Field(*principal, "email").empty() ||
        Field(*data, "csrf_token").empty()) {
      user_id_.clear();
      csrf_.clear();
      prefs->ClearPref(aegis::link::kEmail);
      RejectJavascriptCallback(id, base::Value("signin"));
      return;
    }
    user_id_ = Field(*principal, "id");
    csrf_ = Field(*data, "csrf_token");
    prefs->SetString(aegis::link::kEmail, Field(*principal, "email"));

    base::DictValue result;
    result.Set("id", user_id_);
    result.Set("email", Field(*principal, "email"));
    result.Set("origin", url::Origin::Create(Portal()).Serialize());
    ResolveJavascriptCallback(id, result);
    // 会话和 CSRF 由门户验证成功后，首启窗口才能恢复启动请求。
    if (auto* choice =
            aegis::link::FirstRunChoice::From(web_ui()->GetWebContents()))
      choice->Complete();
    return;
  }
  ResolveJavascriptCallback(id, *data);
}
