// Copyright 2026 GCSA
#include "chrome/browser/aegis/enhancements/enhancement_tab_helper.h"
#include "base/containers/span.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/enhancements/enhancement_store.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/grit/aegis_resources_map.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/referrer.h"
#include "net/base/filename_util.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/resource/resource_bundle.h"
#include "url/origin.h"
namespace aegis {
namespace {
std::map<std::string, EnhancementTabHelper*>& Helpers() {
  static base::NoDestructor<std::map<std::string, EnhancementTabHelper*>> h;
  return *h;
}
std::string JSON(const base::ValueView& value) {
  return base::WriteJson(value).value_or("null");
}
std::string ContextKey(const std::string& session, int id) {
  return session + ":" + base::NumberToString(id);
}
bool Flag(const base::DictValue& value, std::string_view key) {
  return value.FindBool(key).value_or(false);
}
base::DictValue Failure(std::string message) {
  return base::DictValue().Set("error", std::move(message));
}
}  // namespace
std::string EnhancementAsset(std::string_view name) {
  const std::string path = "enhancements_shared/" + std::string(name);
  for (const auto& resource : kAegisResources)
    if (resource.path == path)
      return ui::ResourceBundle::GetSharedInstance().LoadDataResourceString(
          resource.id);
  return "";
}
WEB_CONTENTS_USER_DATA_KEY_IMPL(EnhancementTabHelper);
EnhancementTabHelper::EnhancementTabHelper(content::WebContents* contents)
    : content::WebContentsObserver(contents),
      content::WebContentsUserData<EnhancementTabHelper>(*contents),
      profile_(Profile::FromBrowserContext(contents->GetBrowserContext())),
      store_(EnhancementStore::Get(profile_)),
      id_(base::Uuid::GenerateRandomV4().AsLowercaseString()) {
  Helpers()[id_] = this;
  subscription_ = store_->Observe(
      base::BindRepeating(&EnhancementTabHelper::Rebuild, weak_.GetWeakPtr()));
  Rebuild();
}
EnhancementTabHelper::~EnhancementTabHelper() {
  Helpers().erase(id_);
  if (host_)
    host_->DetachClient(this);
}
bool EnhancementTabHelper::MayReadLocalFiles() {
  return false;
}
bool EnhancementTabHelper::MayWriteLocalFiles() {
  return false;
}
bool EnhancementTabHelper::MayAttachToURL(const GURL& url, bool is_webui) {
  return url.SchemeIsHTTPOrHTTPS() || url.SchemeIs("chrome") ||
         url.IsAboutBlank() || url.is_empty();
}
base::ListValue EnhancementTabHelper::Tabs(Profile* profile) {
  base::ListValue result;
  for (const auto& [id, helper] : Helpers())
    if (helper->profile_ == profile &&
        helper->web_contents()->GetLastCommittedURL().SchemeIsHTTPOrHTTPS())
      result.Append(helper->Snapshot());
  return result;
}
EnhancementTabHelper* EnhancementTabHelper::Find(Profile* profile,
                                                 const std::string& id) {
  auto i = Helpers().find(id);
  return i != Helpers().end() && i->second->profile_ == profile ? i->second
                                                                : nullptr;
}
base::DictValue EnhancementTabHelper::Snapshot() const {
  base::ListValue menus;
  for (const auto& [id, m] : menus_) {
    auto binding = bindings_.find(m.binding);
    if (binding != bindings_.end())
      menus.Append(base::DictValue().Set("id", id).Set("label", m.label)
                       .Set("script", EnhancementField(binding->second.script, "id")));
  }
  return base::DictValue()
      .Set("id", id_)
      .Set("document", base::NumberToString(navigation_id_))
      .Set("url", web_contents()->GetLastCommittedURL().spec())
      .Set("title", web_contents()->GetTitle())
      .Set("statuses", statuses_.Clone())
      .Set("menus", std::move(menus))
      .Set("error", error_);
}
void EnhancementTabHelper::Send(std::string method,
                                base::DictValue params,
                                Reply reply,
                                const std::string& session) {
  if (!host_) {
    if (reply)
      std::move(reply).Run(Failure("页面注入尚未连接，请重新载入。"));
    return;
  }
  const int id = ++next_id_;
  if (reply)
    pending_[id] = std::move(reply);
  base::DictValue request = base::DictValue()
                                .Set("id", id)
                                .Set("method", std::move(method))
                                .Set("params", std::move(params));
  if (!session.empty())
    request.Set("sessionId", session);
  std::string json = JSON(request);
  host_->DispatchProtocolMessage(this, base::as_byte_span(json));
}
void EnhancementTabHelper::Rebuild() {
  if (host_) {
    host_->DetachClient(this);
    host_.reset();
  }
  auto pending = std::move(pending_);
  for (auto& [id, reply] : pending)
    if (reply)
      std::move(reply).Run(Failure("脚本授权已变化。"));
  contexts_.clear();
  bindings_.clear();
  menus_.clear();
  statuses_.clear();
  main_frame_.clear();
  if (!MayAttachToURL(web_contents()->GetLastCommittedURL(),
                      web_contents()->GetWebUI() != nullptr))
    return;
  host_ = content::DevToolsAgentHost::GetOrCreateFor(web_contents());
  if (!host_->AttachClient(this)) {
    host_.reset();
    error_ = "无法建立网页增强会话。";
    return;
  }
  error_.clear();
  for (const auto& item : *store_->state().FindList("scripts"))
    if (Flag(item.GetDict(), "enabled")) {
      std::string name =
          "aegis_" + base::Uuid::GenerateRandomV4().AsLowercaseString();
      bindings_.emplace(name, Binding{item.GetDict().Clone(), false, {}});
    }
  Configure("", false);
}
void EnhancementTabHelper::Configure(const std::string& session, bool paused) {
  Send("Page.enable", {}, {}, session);
  Send("Runtime.enable", {}, {}, session);
  Send("Target.setAutoAttach",
       base::DictValue()
           .Set("autoAttach", true)
           .Set("waitForDebuggerOnStart", true)
           .Set("flatten", true)
           .Set("filter", base::ListValue()
                              .Append(base::DictValue().Set("type", "iframe"))
                              .Append(base::DictValue().Set("exclude", true))),
       {}, session);
  Send("Page.getFrameTree", {},
       base::BindOnce(
           [](base::WeakPtr<EnhancementTabHelper> self, std::string session,
              base::DictValue result) {
             if (!self || !session.empty())
               return;
             if (const auto* frame =
                     result.FindDictByDottedPath("result.frameTree.frame"))
               self->main_frame_ = EnhancementField(*frame, "id");
           },
           weak_.GetWeakPtr(), session),
       session);
  const std::string core = EnhancementAsset("core.js"),
                    rules = EnhancementAsset("site_rules.js");
  if (core.empty() || rules.empty()) {
    error_ = "网页增强资源缺失。";
    if (paused)
      Send("Runtime.runIfWaitingForDebugger", {}, {}, session);
    return;
  }
  Send("Page.addScriptToEvaluateOnNewDocument",
       base::DictValue().Set(
           "source", "(()=>{if(!/^https?:$/.test(location.protocol))return;\n" +
                         core + "\n" + rules +
                         "\n(()=>{const r=AegisEnhancementsCore.siteRule(" +
                         JSON(*store_->state().FindList("sites")) +
                         ",location.href);if(r&&!r.disabled)"
                         "AegisInstallSiteRules(r);})();})();"),
       {}, session);
  for (const auto& [name, binding] : bindings_) {
    if (binding.trial)
      continue;
    const bool isolated = EnhancementField(binding.script, "world") != "page";
    if (isolated)
      Send(
          "Runtime.addBinding",
          base::DictValue().Set("name", name).Set("executionContextName", name),
          {}, session);
    base::DictValue params;
    params.Set("source", Source(binding.script, name, false));
    if (isolated)
      params.Set("worldName", name);
    Send("Page.addScriptToEvaluateOnNewDocument", std::move(params), {},
         session);
  }
  // 与上面的注册命令在同一会话顺序处理，子框架只在注册完成后继续加载。
  if (paused)
    Send("Runtime.runIfWaitingForDebugger", {}, {}, session);
}
std::string EnhancementTabHelper::Source(const base::DictValue& script,
                                         const std::string& name,
                                         bool trial) {
  const auto& metadata = *script.FindDict("metadata");
  const bool page = EnhancementField(script, "world") == "page";
  std::string source =
      "(()=>{if(!/^https?:$/.test(location.protocol))return 'unmatched';\n" +
      EnhancementAsset("core.js") + "\n" +
      EnhancementAsset("script_runtime.js") +
      "\n(()=>{'use strict';const metadata=" + JSON(metadata) +
      ";if(!AegisEnhancementsCore.applies(metadata,location.href,window==="
      "window.top," +
      (Flag(script, "allFrames") ? "true" : "false") +
      "))return 'unmatched';const key=" +
      JSON(base::Value("__aegisRan_" + name)) +
      ";if(globalThis[key])return 'duplicate';globalThis[key]=true;";
  if (const auto* disabled = script.FindList("disabledOrigins"))
    source += "if(" + JSON(base::Value(disabled->Clone())) +
              ".some(origin=>[location.origin,...Array.from(location.ancestorOrigins||[])].includes(origin)))return 'paused';";
  if (page)
    source += "const runtime={api:{},report:(s,e)=>{if(e)console.warn(e)}};";
  else
    source +=
        "const send=globalThis[" + JSON(base::Value(name)) +
        "];const "
        "runtime=AegisCreateScriptRuntime(metadata,send);globalThis.__"
        "aegisReply=runtime.receive;globalThis.__aegisMenu=runtime.runMenu;";
  source +=
      "const {GM,GM_addStyle,GM_registerMenuCommand}=runtime.api;const "
      "run=async()=>{runtime.report('running');try{await(async()=>{\n" +
      EnhancementField(script, "source") +
      "\n})();runtime.report('completed');}catch(e){runtime.report('failed',"
      "String(e));}};";
  const auto when = EnhancementField(metadata, "runAt");
  if (trial || when == "document-start")
    source += "void run();";
  else
    source +=
        "const ready=()=>{" +
        std::string(when == "document-idle"
                        ? "requestIdleCallback(()=>void run(),{timeout:1000});"
                        : "void run();") +
        "};if(document.readyState==='loading')document.addEventListener('"
        "DOMContentLoaded',ready,{once:true});else ready();";
  return source + "return 'scheduled';})();})();";
}
void EnhancementTabHelper::DispatchProtocolMessage(
    content::DevToolsAgentHost*,
    base::span<const uint8_t> bytes) {
  if (bytes.size() > 3 * 1024 * 1024)
    return;
  auto message = base::JSONReader::ReadDict(
      std::string_view(reinterpret_cast<const char*>(bytes.data()),
                       bytes.size()),
      base::JSON_PARSE_RFC);
  if (!message)
    return;
  if (auto id = message->FindInt("id")) {
    auto node = pending_.extract(*id);
    if (!node.empty() && node.mapped())
      std::move(node.mapped()).Run(std::move(*message));
    return;
  }
  const auto method = EnhancementField(*message, "method"),
             session = EnhancementField(*message, "sessionId");
  const auto* params = message->FindDict("params");
  if (!params)
    return;
  if (method == "Target.attachedToTarget") {
    const auto child = EnhancementField(*params, "sessionId");
    const auto* target = params->FindDict("targetInfo");
    if (target && EnhancementField(*target, "type") == "iframe") {
      // 原生客户端同步收到事件时，Chromium 尚未登记子框架导航暂停器。
      // 下一轮任务再注册并恢复，避免提前恢复后新登记的暂停器永远不释放。
      base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
          FROM_HERE, base::BindOnce(&EnhancementTabHelper::Configure,
                                   weak_.GetWeakPtr(), child,
                                   Flag(*params, "waitingForDebugger")));
    }
    else
      Send("Runtime.runIfWaitingForDebugger", {}, {}, child);
  } else if (method == "Runtime.executionContextCreated") {
    const auto* context = params->FindDict("context");
    if (!context)
      return;
    const auto* aux = context->FindDict("auxData");
    if (!aux)
      return;
    Context c;
    c.id = context->FindInt("id").value_or(0);
    c.unique = EnhancementField(*context, "uniqueId");
    c.world = EnhancementField(*context, "name");
    c.frame = EnhancementField(*aux, "frameId");
    c.page = Flag(*aux, "isDefault");
    c.session = session;
    if (!c.unique.empty())
      contexts_[ContextKey(session, c.id)] = std::move(c);
  } else if (method == "Runtime.executionContextDestroyed")
    contexts_.erase(
        ContextKey(session, params->FindInt("executionContextId").value_or(0)));
  else if (method == "Runtime.executionContextsCleared")
    std::erase_if(contexts_, [&](const auto& item) {
      return item.second.session == session;
    });
  else if (method == "Runtime.bindingCalled")
    BindingCalled(session, *params);
  else if (method == "Page.frameNavigated" && session.empty()) {
    const auto* frame = params->FindDict("frame");
    if (frame && !frame->FindString("parentId")) {
      main_frame_ = EnhancementField(*frame, "id");
      menus_.clear();
      statuses_.clear();
    }
  } else if (method == "Target.detachedFromTarget") {
    const auto child = EnhancementField(*params, "sessionId");
    std::erase_if(contexts_, [&](const auto& item) {
      return item.second.session == child;
    });
  }
}
void EnhancementTabHelper::BindingCalled(const std::string& session,
                                         const base::DictValue& params) {
  const auto name = EnhancementField(params, "name"),
             payload = EnhancementField(params, "payload");
  auto binding = bindings_.find(name);
  auto context = contexts_.find(
      ContextKey(session, params.FindInt("executionContextId").value_or(0)));
  if (binding == bindings_.end() || context == contexts_.end() ||
      context->second.world != name || payload.size() > 8192)
    return;
  auto body = base::JSONReader::ReadDict(payload, base::JSON_PARSE_RFC);
  if (!body || EnhancementField(*body, "request").size() > 30)
    return;
  // 来源来自浏览器记录的执行环境及该文档的实时 URL，页面不能提供待校验 URL。
  Send("Runtime.evaluate",
       base::DictValue()
           .Set("expression", "location.href")
           .Set("uniqueContextId", context->second.unique)
           .Set("returnByValue", true),
       base::BindOnce(&EnhancementTabHelper::HandleBinding, weak_.GetWeakPtr(),
                      context->second, name, std::move(*body)),
       session);
}
void EnhancementTabHelper::HandleBinding(Context context,
                                         std::string name,
                                         base::DictValue body,
                                         base::DictValue result) {
  auto it = bindings_.find(name);
  auto current = contexts_.find(ContextKey(context.session, context.id));
  if (it == bindings_.end() || current == contexts_.end() ||
      current->second.unique != context.unique)
    return;
  auto& binding = it->second;
  const auto id = EnhancementField(binding.script, "id");
  const auto* actual = store_->Script(id);
  const auto* value = result.FindStringByDottedPath("result.result.value");
  std::string error;
  base::Value answer;
  if (!value || !actual ||
      actual->FindInt("revision") != binding.script.FindInt("revision") ||
      (!binding.trial && !Flag(*actual, "enabled")) ||
      EnhancementStore::PausedAt(*actual, web_contents()->GetLastCommittedURL()) ||
      (value && EnhancementStore::PausedAt(*actual, GURL(*value))) ||
      !EnhancementStore::Applies(*actual, GURL(*value),
                                 context.frame == main_frame_))
    error = "页面或脚本授权已变化。";
  else {
    const auto op = EnhancementField(body, "op"),
               key = EnhancementField(body, "key");
    const auto* grants = actual->FindDict("metadata")->FindList("grants");
    const auto granted = [&](const char* grant) {
      return grants->contains(grant);
    };
    if (op == "get" || op == "set" || op == "delete") {
      const char* grant = op == "get"   ? "GM.getValue"
                          : op == "set" ? "GM.setValue"
                                        : "GM.deleteValue";
      if (!granted(grant) || key.empty() || key.size() > 200)
        error = "未授权的存储操作。";
      else if (op == "get") {
        if (binding.trial) {
          if (const auto* saved = binding.values.Find(key))
            answer = saved->Clone();
        } else {
          auto saved = store_->Value(id, key);
          if (saved)
            answer = std::move(*saved);
        }
      } else if (binding.trial) {
        auto next = binding.values.Clone();
        if (op == "delete")
          next.Remove(key);
        else if (const auto* saved = body.Find("value")) {
          if (JSON(*saved).size() > 4096)
            error = "存储值超过 4 KiB。";
          else
            next.Set(key, saved->Clone());
        } else
          error = "缺少存储值。";
        if (next.size() > 128 || JSON(next).size() > 65536)
          error = "试运行存储超限。";
        if (error.empty())
          binding.values = std::move(next);
      } else if (op == "set" && !body.Find("value"))
        error = "缺少存储值。";
      else {
        store_->SetValue(
            id, key, op == "delete" ? nullptr : body.Find("value"),
            base::BindOnce(&EnhancementTabHelper::ReplyBinding,
                           weak_.GetWeakPtr(), context,
                           EnhancementField(body, "request"), base::Value()),
            actual->FindInt("revision").value_or(0));
        return;
      }
    } else if (op == "menu") {
      const auto label = EnhancementField(body, "label");
      if (!granted("GM_registerMenuCommand") || label.empty() ||
          label.size() > 400 || key.size() > 10 || menus_.size() >= 128)
        error = "脚本菜单无效。";
      else
        menus_[name + ":" + context.unique + ":" + key] =
            Menu{name, key, label, ContextKey(context.session, context.id)};
    } else if (op == "report")
      statuses_.Set(
          id,
          base::DictValue()
              .Set("status", EnhancementField(body, "status").substr(0, 100))
              .Set("trial", binding.trial)
              .Set("mainFrame", context.frame == main_frame_)
              .Set("error", EnhancementField(body, "error").substr(0, 1000)));
    else
      error = "未知脚本操作。";
  }
  ReplyBinding(context, EnhancementField(body, "request"), std::move(answer),
               error);
}
void EnhancementTabHelper::ReplyBinding(Context context,
                                        std::string request,
                                        base::Value value,
                                        std::string error) {
  const auto it = contexts_.find(ContextKey(context.session, context.id));
  if (it == contexts_.end() || it->second.unique != context.unique)
    return;
  base::DictValue reply =
      base::DictValue().Set("request", request).Set("value", std::move(value));
  if (!error.empty())
    reply.Set("error", error);
  Send("Runtime.evaluate",
       base::DictValue()
           .Set("expression", "globalThis.__aegisReply(" + JSON(reply) + ")")
           .Set("uniqueContextId", context.unique),
       {}, context.session);
}
const EnhancementTabHelper::Context* EnhancementTabHelper::MainContext() const {
  for (const auto& [key, c] : contexts_)
    if (c.page && c.frame == main_frame_ && c.session.empty())
      return &c;
  return nullptr;
}
void EnhancementTabHelper::Trial(const std::string& id, Reply reply) {
  const auto* script = store_->Script(id);
  const auto* context = MainContext();
  if (!script || !context ||
      !EnhancementStore::Applies(*script, web_contents()->GetLastCommittedURL(),
                                 true)) {
    std::move(reply).Run(Failure("当前页面不在脚本范围内，或尚未完成加载。"));
    return;
  }
  const std::string name =
      "aegis_" + base::Uuid::GenerateRandomV4().AsLowercaseString();
  bindings_.emplace(name, Binding{script->Clone(), true, {}});
  const std::string source = Source(*script, name, true);
  if (EnhancementField(*script, "world") == "page") {
    Send("Runtime.evaluate",
         base::DictValue()
             .Set("expression", source)
             .Set("uniqueContextId", context->unique)
             .Set("returnByValue", true),
         std::move(reply));
    return;
  }
  Send("Runtime.addBinding",
       base::DictValue().Set("name", name).Set("executionContextName", name));
  Send(
      "Page.createIsolatedWorld",
      base::DictValue().Set("frameId", main_frame_).Set("worldName", name),
      base::BindOnce(
          [](base::WeakPtr<EnhancementTabHelper> self, std::string source,
             int64_t navigation, Reply reply, base::DictValue result) {
            if (!self)
              return;
            auto id = result.FindIntByDottedPath("result.executionContextId");
            const auto context = id ? self->contexts_.find(ContextKey("", *id))
                                    : self->contexts_.end();
            if (!id || self->navigation_id_ != navigation ||
                context == self->contexts_.end()) {
              std::move(reply).Run(Failure("页面已变化或无法创建试运行环境。"));
              return;
            }
            self->Send("Runtime.evaluate",
                       base::DictValue()
                           .Set("expression", source)
                           .Set("uniqueContextId", context->second.unique)
                           .Set("returnByValue", true),
                       std::move(reply));
          },
          weak_.GetWeakPtr(), source, navigation_id_, std::move(reply)));
}
void EnhancementTabHelper::RunMenu(const std::string& id, Reply reply) {
  auto menu = menus_.find(id);
  if (menu == menus_.end()) {
    std::move(reply).Run(Failure("菜单已过期。"));
    return;
  }
  auto context = contexts_.find(menu->second.context);
  if (context == contexts_.end()) {
    std::move(reply).Run(Failure("页面已经变化。"));
    return;
  }
  const auto saved = menu->second;
  const auto ctx = context->second;
  Send("Runtime.evaluate",
       base::DictValue()
           .Set("expression", "location.href")
           .Set("uniqueContextId", ctx.unique)
           .Set("returnByValue", true),
       base::BindOnce(
           [](base::WeakPtr<EnhancementTabHelper> self, Menu menu, Context ctx,
              Reply reply, base::DictValue result) {
             if (!self)
               return;
             auto binding = self->bindings_.find(menu.binding);
             auto current = self->contexts_.find(menu.context);
             const auto* address =
                 result.FindStringByDottedPath("result.result.value");
             const auto* script = binding == self->bindings_.end()
                                      ? nullptr
                                      : self->store_->Script(EnhancementField(
                                            binding->second.script, "id"));
             if (!address || !script || current == self->contexts_.end() ||
                 current->second.unique != ctx.unique ||
                 script->FindInt("revision") !=
                     binding->second.script.FindInt("revision") ||
                 (!binding->second.trial && !Flag(*script, "enabled")) ||
                 EnhancementStore::PausedAt(*script, self->web_contents()->GetLastCommittedURL()) ||
                 (address && EnhancementStore::PausedAt(*script, GURL(*address))) ||
                 !EnhancementStore::Applies(*script, GURL(*address),
                                            ctx.frame == self->main_frame_)) {
               std::move(reply).Run(Failure("菜单授权已经变化。"));
               return;
             }
             self->Send(
                 "Runtime.evaluate",
                 base::DictValue()
                     .Set("expression", "globalThis.__aegisMenu(" +
                                            JSON(base::Value(menu.key)) + ")")
                     .Set("uniqueContextId", ctx.unique),
                 std::move(reply), ctx.session);
           },
           weak_.GetWeakPtr(), saved, ctx, std::move(reply)),
       ctx.session);
}
void EnhancementTabHelper::ReadPage(bool markdown, Reply reply) {
  const auto* context = MainContext();
  if (!context) {
    std::move(reply).Run(Failure("页面尚未准备好。"));
    return;
  }
  const std::string expression =
      markdown
          ? R"JS((()=>{if(!/^(text\/(plain|markdown|x-markdown))($|;)/i.test(document.contentType))throw Error('当前响应不是 Markdown 或纯文本');const text=document.body?.innerText||'';if(new TextEncoder().encode(text).length>2097152)throw Error('文档超过 2 MiB');return {text,title:document.title||location.pathname,baseURL:location.href};})())JS"
          : R"JS((()=>({url:location.href,title:document.title,structure:[...document.querySelectorAll('main,article,aside,nav,h1,h2,h3,button')].slice(0,120).map(e=>({tag:e.tagName,id:e.id,classes:String(e.className).slice(0,100),text:/^(H[123]|BUTTON)$/.test(e.tagName)?e.textContent.slice(0,150):''}))}))())JS";
  Send("Runtime.evaluate",
       base::DictValue()
           .Set("expression", expression)
           .Set("uniqueContextId", context->unique)
           .Set("returnByValue", true),
       std::move(reply));
}
void EnhancementTabHelper::Recover(Reply reply) {
  store_->Mutate(base::DictValue().Set("op", "disable-all"),
                 base::BindOnce(
                     [](base::WeakPtr<EnhancementTabHelper> self, Reply reply,
                        std::string error) {
                       if (!self)
                         return;
                       if (!error.empty()) {
                         std::move(reply).Run(Failure(error));
                         return;
                       }
                       self->Send("Runtime.terminateExecution");
                       self->web_contents()->GetController().Reload(
                           content::ReloadType::NORMAL, true);
                       std::move(reply).Run({});
                     },
                     weak_.GetWeakPtr(), std::move(reply)));
}
void EnhancementTabHelper::Inspect() {
  DevToolsWindow::OpenDevToolsWindow(
      web_contents(), DevToolsOpenedByAction::kMainMenuOrMainShortcut);
}
void EnhancementTabHelper::DidFinishNavigation(
    content::NavigationHandle* handle) {
  if (!handle->IsInPrimaryMainFrame() || !handle->HasCommitted() ||
      handle->IsSameDocument())
    return;
  menus_.clear();
  statuses_.clear();
  std::erase_if(bindings_, [](const auto& i) { return i.second.trial; });
  if (!host_)
    Rebuild();
}
base::DictValue EnhancementTabHelper::TakeMarkdown() {
  return std::move(markdown_);
}
void EnhancementTabHelper::ReadMarkdownFile(base::FilePath path,
                                            GURL source,
                                            bool local,
                                            Reply reply) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(
          [](base::FilePath path, GURL source, bool local) {
            std::string text;
            auto size = base::GetFileSize(path);
            if (!size || *size > 2097152 ||
                !base::ReadFileToStringWithMaxSize(path, &text, 2097152) ||
                !base::IsStringUTF8(text) || text.contains('\0'))
              return Failure("文档超过 2 MiB、不是 UTF-8，或已无法读取。");
            return base::DictValue()
                .Set("text", text)
                .Set("title", path.BaseName().AsUTF8Unsafe())
                .Set("baseURL", source.spec())
                .Set("local", local);
          },
          std::move(path), std::move(source), local),
      std::move(reply));
}
void EnhancementTabHelper::DidStartNavigation(
    content::NavigationHandle* handle) {
  if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument())
    return;
  navigation_id_ = handle->GetNavigationId();
  const auto url = handle->GetURL();
  if (!handle->IsRendererInitiated() && url.SchemeIsFile() &&
      (url.host().empty() || url.host() == "localhost")) {
    base::FilePath path;
    if (!net::FileURLToFilePath(url, &path))
      return;
    const auto extension = base::ToLowerASCII(path.FinalExtension());
    if (extension != FILE_PATH_LITERAL(".md") &&
        extension != FILE_PATH_LITERAL(".markdown"))
      return;
    ReadMarkdownFile(
        path, url, true,
        base::BindOnce(
            [](base::WeakPtr<EnhancementTabHelper> self, int64_t navigation,
               base::DictValue result) {
              if (!self || self->navigation_id_ != navigation ||
                  result.FindString("error"))
                return;
              self->markdown_ = std::move(result);
              self->web_contents()->Stop();
              self->web_contents()->GetController().LoadURL(
                  GURL("chrome://aegis/markdown.html"), content::Referrer(),
                  ui::PAGE_TRANSITION_AUTO_TOPLEVEL, std::string());
            },
            weak_.GetWeakPtr(), navigation_id_));
  }
}
void EnhancementTabHelper::DidFinishLoad(content::RenderFrameHost* frame,
                                         const GURL& url) {
  if (frame != web_contents()->GetPrimaryMainFrame() ||
      !url.SchemeIsHTTPOrHTTPS())
    return;
  const std::string path = base::ToLowerASCII(std::string(url.path()));
  if (!path.ends_with(".md") && !path.ends_with(".markdown") &&
      web_contents()->GetContentsMimeType() != "text/markdown")
    return;
  const auto* sites = store_->state().FindDict("markdownSites");
  if (!sites || sites->FindBool(url::Origin::Create(url).Serialize()) != true)
    return;
  ReadPage(true, base::BindOnce(
                     [](base::WeakPtr<EnhancementTabHelper> self, GURL url,
                        int64_t navigation, base::DictValue result) {
                       if (!self || self->navigation_id_ != navigation ||
                           self->web_contents()->GetLastCommittedURL() != url)
                         return;
                       const auto* value =
                           result.FindDictByDottedPath("result.result.value");
                       if (!value || !value->FindString("text"))
                         return;
                       self->markdown_ = value->Clone();
                       self->markdown_.Set("local", false);
                       self->web_contents()->GetController().LoadURL(
                           GURL("chrome://aegis/markdown.html"),
                           content::Referrer(),
                           ui::PAGE_TRANSITION_AUTO_TOPLEVEL, std::string());
                     },
                     weak_.GetWeakPtr(), url, navigation_id_));
}
void EnhancementTabHelper::AgentHostClosed(content::DevToolsAgentHost*) {
  host_.reset();
  contexts_.clear();
  error_ = "网页增强连接已结束，请重新载入。";
}
}  // namespace aegis
