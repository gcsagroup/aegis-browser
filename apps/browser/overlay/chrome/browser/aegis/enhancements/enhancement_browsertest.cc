// Copyright 2026 GCSA
// 浏览器进程验收：真实文档注入、授权撤销与无特权 Markdown 渲染。
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/test_future.h"
#include "chrome/browser/aegis/enhancements/enhancement_store.h"
#include "chrome/browser/aegis/enhancements/enhancement_tab_helper.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/browser_test.h"
#include "content/public/test/browser_test_utils.h"
#include "content/public/test/test_devtools_protocol_client.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "net/dns/mock_host_resolver.h"
#include "net/test/embedded_test_server/http_response.h"
#include "url/origin.h"

namespace aegis {
class EnhancementBrowserTest : public InProcessBrowserTest {
 protected:
  void SetUpCommandLine(base::CommandLine* command_line) override {
    command_line->AppendSwitch("site-per-process");
  }
  void SetUpOnMainThread() override {
    host_resolver()->AddRule("frame.test", "127.0.0.1");
    embedded_test_server()->RegisterRequestHandler(base::BindLambdaForTesting(
        [this](const net::test_server::HttpRequest& request)
            -> std::unique_ptr<net::test_server::HttpResponse> {
          auto response =
              std::make_unique<net::test_server::BasicHttpResponse>();
          response->set_content_type("text/html");
          response->set_content(
              "<!doctype "
              "html><script>document.dispatchEvent(new "
              "Event('aegis-probe'));window.early=document.documentElement."
              "dataset."
              "early==='yes';window.addEventListener('contextmenu',e=>e."
              "preventDefault(),true)</script><h1>原文</h1><aside>侧栏</"
              "aside>");
          if (request.relative_url == "/frames")
            response->set_content(
                "<h1>框架验收</h1><iframe src='/frame'></iframe><iframe src='" +
                embedded_test_server()->GetURL("frame.test", "/frame").spec() +
                "'></iframe>");
          return response;
        }));
    ASSERT_TRUE(embedded_test_server()->Start());
    store_ = EnhancementStore::Get(browser()->GetProfile());
    ASSERT_TRUE(base::test::RunUntil([&] { return store_->ready(); }));
  }
  content::WebContents* contents() {
    return browser()->tab_strip_model()->GetActiveWebContents();
  }
  std::string Mutate(base::DictValue request) {
    base::test::TestFuture<std::string> result;
    store_->Mutate(request, result.GetCallback());
    return result.Get();
  }
  std::string Save(std::string code,
                   std::string grants = "none",
                   std::string when = "document-end",
                   bool all_frames = false) {
    const auto source =
        "// ==UserScript==\n// @name 浏览器验收\n// @match "
        "http://127.0.0.1/*\n// @run-at " +
        when + "\n// @grant " + grants + "\n// ==/UserScript==\n" + code;
    EXPECT_EQ(Mutate(base::DictValue()
                         .Set("op", "script-save")
                         .Set("source", source)
                         .Set("world", "isolated")
                         .Set("allFrames", all_frames)),
              "");
    return EnhancementField(
        store_->state().FindList("scripts")->back().GetDict(), "id");
  }
  raw_ptr<EnhancementStore> store_ = nullptr;
};
IN_PROC_BROWSER_TEST_F(EnhancementBrowserTest,
                       EarlyRulesIsolationStorageAndRevocation) {
  const auto url = embedded_test_server()->GetURL("/page");
  ASSERT_EQ(
      Mutate(base::DictValue()
                 .Set("op", "site-save")
                 .Set("rule",
                      base::DictValue()
                          .Set("origin", url::Origin::Create(url).Serialize())
                          .Set("menu", true)
                          .Set("copy", true)
                          .Set("debug", true)
                          .Set("subdomains", false)
                          .Set("disabled", false))),
      "");
  auto early = Save(
      "document.addEventListener('aegis-probe',()=>document.documentElement."
      "dataset.early='yes');",
      "none", "document-start");
  ASSERT_EQ(Mutate(base::DictValue()
                       .Set("op", "script-enable")
                       .Set("id", early)
                       .Set("revision", 1)
                       .Set("enabled", true)),
            "");
  auto id = Save(
      "globalThis.secret='hidden';await GM.setValue('count',(await "
      "GM.getValue('count',0))+1);GM_registerMenuCommand('测试菜单',()=>"
      "document.body.dataset.menu='called');document.body.dataset.done='yes';",
      "GM.getValue\n// @grant GM.setValue\n// @grant GM_registerMenuCommand");
  ASSERT_EQ(Mutate(base::DictValue()
                       .Set("op", "script-enable")
                       .Set("id", id)
                       .Set("revision", 1)
                       .Set("enabled", true)),
            "");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), url));
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return store_->Value(id, "count") == base::Value(1); }));
  EXPECT_EQ(true, content::EvalJs(contents(), "window.early"));
  EXPECT_EQ("undefined", content::EvalJs(contents(), "typeof window.secret"));
  EXPECT_EQ(true,
            content::EvalJs(contents(),
                            "window.dispatchEvent(new "
                            "MouseEvent('contextmenu',{cancelable:true}))"));
  EXPECT_EQ(42, content::EvalJs(contents(), "Function('return 42')()"));
  content::TestDevToolsProtocolClient debugger;
  debugger.AttachToWebContents(contents());
  debugger.SendCommandSync("Debugger.enable");
  debugger.SendCommandAsync(
      "Runtime.evaluate", base::DictValue().Set("expression", "debugger; 42"));
  auto pause = debugger.WaitForNotification("Debugger.paused", true);
  EXPECT_FALSE(pause.empty());
  debugger.SendCommandSync("Debugger.resume");
  debugger.DetachProtocolClient();
  auto* helper = EnhancementTabHelper::FromWebContents(contents());
  ASSERT_NE(helper, nullptr);
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return !helper->Snapshot().FindList("menus")->empty(); }));
  const auto menu = EnhancementField(
      helper->Snapshot().FindList("menus")->front().GetDict(), "id");
  base::test::TestFuture<base::DictValue> called;
  helper->RunMenu(menu, called.GetCallback());
  EXPECT_FALSE(called.Get().Find("error"));
  EXPECT_EQ("called",
            content::EvalJs(contents(), "document.body.dataset.menu"));
  ASSERT_EQ(Mutate(base::DictValue().Set("op", "disable-all")), "");
  base::test::TestFuture<base::DictValue> revoked;
  helper->RunMenu(menu, revoked.GetCallback());
  EXPECT_TRUE(revoked.Get().Find("error"));
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), url));
  EXPECT_EQ("undefined",
            content::EvalJs(contents(), "typeof document.body.dataset.done"));
  EXPECT_EQ(store_->Value(id, "count"), base::Value(1));
}
IN_PROC_BROWSER_TEST_F(EnhancementBrowserTest,
                       TrialDoesNotPersistAndPrivateProfileStartsEmpty) {
  const auto id =
      Save("await GM.setValue('trial',42);document.body.dataset.trial='yes';",
           "GM.setValue");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/page")));
  auto* helper = EnhancementTabHelper::FromWebContents(contents());
  base::test::TestFuture<base::DictValue> trial;
  helper->Trial(id, trial.GetCallback());
  EXPECT_FALSE(trial.Get().Find("error"));
  ASSERT_TRUE(base::test::RunUntil([&] {
    return content::EvalJs(contents(), "document.body.dataset.trial||''")
               .ExtractString() == "yes";
  }));
  EXPECT_FALSE(store_->Value(id, "trial"));
  EXPECT_EQ(store_->Script(id)->FindBool("enabled"), false);
  auto* private_store = EnhancementStore::Get(
      browser()->GetProfile()->GetPrimaryOTRProfile(true));
  EXPECT_TRUE(private_store->state().FindList("scripts")->empty());
}
IN_PROC_BROWSER_TEST_F(EnhancementBrowserTest,
                       CrossProcessFramesAreMatchedIndividually) {
  auto id = Save(
      "GM_registerMenuCommand(window===top?'主页面':'同源框架',()=>{});"
      "document.body.dataset.script='matched';",
      "GM_registerMenuCommand", "document-end", true);
  ASSERT_EQ(Mutate(base::DictValue()
                       .Set("op", "script-enable")
                       .Set("id", id)
                       .Set("revision", 1)
                       .Set("enabled", true)),
            "");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), embedded_test_server()->GetURL("/frames")));
  auto* main = contents()->GetPrimaryMainFrame();
  auto* same = content::ChildFrameAt(main, 0);
  auto* other = content::ChildFrameAt(main, 1);
  ASSERT_NE(same, nullptr);
  ASSERT_NE(other, nullptr);
  EXPECT_NE(main->GetProcess(), other->GetProcess());
  auto* helper = EnhancementTabHelper::FromWebContents(contents());
  ASSERT_TRUE(base::test::RunUntil(
      [&] { return helper->Snapshot().FindList("menus")->size() == 2; }));
  EXPECT_EQ("matched", content::EvalJs(main, "document.body.dataset.script"));
  EXPECT_EQ("matched", content::EvalJs(same, "document.body.dataset.script"));
  EXPECT_EQ("undefined",
            content::EvalJs(other, "typeof document.body.dataset.script"));
  const auto menu = EnhancementField(
      helper->Snapshot().FindList("menus")->front().GetDict(), "id");
  ASSERT_EQ(Mutate(base::DictValue().Set("op", "disable-all")), "");
  base::test::TestFuture<base::DictValue> denied;
  helper->RunMenu(menu, denied.GetCallback());
  EXPECT_TRUE(denied.Get().Find("error"));
}
IN_PROC_BROWSER_TEST_F(EnhancementBrowserTest,
                       MarkdownUntrustedFrameRendersAndBlocksExecutableHTML) {
  ASSERT_TRUE(ui_test_utils::NavigateToURL(
      browser(), GURL("chrome://aegis/markdown.html")));
  auto* frame = content::ChildFrameAt(contents()->GetPrimaryMainFrame(), 0);
  ASSERT_NE(frame, nullptr);
  ASSERT_EQ(frame->GetLastCommittedURL(),
            GURL("chrome-untrusted://aegis-markdown/viewer.html"));
  EXPECT_EQ("undefined", content::EvalJs(frame, "typeof chrome.send"));
  EXPECT_EQ(
      true,
      content::EvalJs(
          frame,
          "AegisMarkdown.load({text:'# "
          "验收\\n\\n<script>window.unsafe=1</script>\\n\\n![外图](https://"
          "invalid.local/a.png)',title:'验收'})"));
  EXPECT_EQ("验收",
            content::EvalJs(
                frame, "document.querySelector('#document h1').textContent"));
  EXPECT_EQ(0,
            content::EvalJs(
                frame, "document.querySelectorAll('#document script').length"));
  EXPECT_EQ("undefined", content::EvalJs(frame, "typeof window.unsafe"));
  EXPECT_EQ("",
            content::EvalJs(
                frame,
                "document.querySelector('#document img').getAttribute('src')"));
  EXPECT_EQ(
      false,
      content::EvalJs(frame, "AegisMarkdown.load({text:'x'.repeat(2097153)})"));
}
}  // namespace aegis
