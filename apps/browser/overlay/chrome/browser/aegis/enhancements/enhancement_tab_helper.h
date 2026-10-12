// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ENHANCEMENTS_ENHANCEMENT_TAB_HELPER_H_
#define CHROME_BROWSER_AEGIS_ENHANCEMENTS_ENHANCEMENT_TAB_HELPER_H_
#include <map>
#include <string>
#include "base/callback_list.h"
#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
class Profile;
namespace aegis {
class EnhancementStore;
class EnhancementTabHelper
    : public content::WebContentsObserver,
      public content::WebContentsUserData<EnhancementTabHelper>,
      public content::DevToolsAgentHostClient {
 public:
  using Reply = base::OnceCallback<void(base::DictValue)>;
  ~EnhancementTabHelper() override;
  static base::ListValue Tabs(Profile* profile);
  static EnhancementTabHelper* Find(Profile* profile, const std::string& id);
  base::DictValue Snapshot() const;
  void Trial(const std::string& id, Reply reply);
  void RunMenu(const std::string& id, Reply reply);
  void ReadPage(bool markdown, Reply reply);
  void Recover(Reply reply);
  void Inspect();
  base::DictValue TakeMarkdown();
  static void ReadMarkdownFile(base::FilePath path,
                               GURL source,
                               bool local,
                               Reply reply);
  void DispatchProtocolMessage(content::DevToolsAgentHost*,
                               base::span<const uint8_t>) override;
  void AgentHostClosed(content::DevToolsAgentHost*) override;
  bool MayAttachToURL(const GURL& url, bool is_webui) override;
  bool MayReadLocalFiles() override;
  bool MayWriteLocalFiles() override;
  void DidStartNavigation(content::NavigationHandle* handle) override;
  void DidFinishLoad(content::RenderFrameHost* frame, const GURL& url) override;
  void DidFinishNavigation(content::NavigationHandle* handle) override;

 private:
  friend class content::WebContentsUserData<EnhancementTabHelper>;
  explicit EnhancementTabHelper(content::WebContents* contents);
  struct Context {
    std::string unique, frame, world, session;
    int id = 0;
    bool page = false;
  };
  struct Binding {
    base::DictValue script;
    bool trial = false;
    base::DictValue values;
  };
  struct Menu {
    std::string binding, key, label, context;
  };
  void Rebuild();
  void Configure(const std::string& session, bool paused);
  void Send(std::string method,
            base::DictValue params = {},
            Reply reply = {},
            const std::string& session = "");
  std::string Source(const base::DictValue& script,
                     const std::string& binding,
                     bool trial);
  void BindingCalled(const std::string& session, const base::DictValue& params);
  void HandleBinding(Context context,
                     std::string name,
                     base::DictValue body,
                     base::DictValue result);
  void ReplyBinding(Context context,
                    std::string request,
                    base::Value value,
                    std::string error);
  const Context* MainContext() const;
  raw_ptr<Profile> profile_;
  raw_ptr<EnhancementStore> store_;
  const std::string id_;
  scoped_refptr<content::DevToolsAgentHost> host_;
  base::CallbackListSubscription subscription_;
  std::map<int, Reply> pending_;
  std::map<std::string, Context> contexts_;
  std::map<std::string, Binding> bindings_;
  std::map<std::string, Menu> menus_;
  base::DictValue statuses_;
  base::DictValue markdown_;
  int64_t navigation_id_ = 0;
  std::string main_frame_, error_;
  int next_id_ = 0;
  base::WeakPtrFactory<EnhancementTabHelper> weak_{this};
  WEB_CONTENTS_USER_DATA_KEY_DECL();
};
std::string EnhancementAsset(std::string_view name);
}  // namespace aegis
#endif
