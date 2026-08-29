// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_workflow.h"

#include "base/no_destructor.h"

namespace aegis::agent {
namespace {

AgentWorkflowTemplate ResearchTemplate() {
  AgentWorkflowTemplate value;
  value.kind = AgentWorkflowKind::kResearch;
  value.id = "research";
  value.title = "深度研究";
  value.purpose = "跨来源读取、提取、比较并保留来源证据";
  value.tools = {"page.observe",   "page.extract",   "page.navigate",
                 "page.scroll",    "page.wait",      "tab.list",
                 "tab.create",     "tab.activate",   "tab.close",
                 "history.search", "monitor.create", "monitor.list",
                 "monitor.pause",  "monitor.delete"};
  value.data_classes = {AgentDataClass::kPublicPage,
                        AgentDataClass::kBrowserMetadata,
                        AgentDataClass::kHistory};
  value.budgets.max_tabs = 12;
  value.budgets.max_tool_calls = 80;
  value.budgets.max_model_calls = 30;
  value.budgets.max_network_requests = 160;
  value.budgets.max_duration = base::Minutes(30);
  value.supports_monitoring = true;
  return value;
}

AgentWorkflowTemplate BrowserStewardTemplate() {
  AgentWorkflowTemplate value;
  value.kind = AgentWorkflowKind::kBrowserSteward;
  value.id = "browser_steward";
  value.title = "浏览器管家";
  value.purpose = "预览、整理并可撤销地管理标签页、工作区和收藏夹";
  value.tools = {"tab.list",       "tab.create",          "tab.activate",
                 "tab.close",      "tab.group",           "window.list",
                 "window.create",  "window.activate",     "window.close",
                 "workspace.save", "workspace.restore",   "bookmark.list",
                 "bookmark.plan",  "bookmark.check_urls", "bookmark.apply",
                 "bookmark.undo",  "monitor.create",      "monitor.list",
                 "monitor.pause",  "monitor.delete"};
  value.data_classes = {AgentDataClass::kBrowserMetadata,
                        AgentDataClass::kBookmarks,
                        AgentDataClass::kPublicPage};
  value.budgets.max_tabs = 20;
  value.budgets.max_tool_calls = 80;
  value.budgets.max_model_calls = 20;
  value.budgets.max_network_requests = 500;
  value.budgets.max_duration = base::Hours(1);
  value.supports_monitoring = true;
  return value;
}

AgentWorkflowTemplate SafeDownloadTemplate() {
  AgentWorkflowTemplate value;
  value.kind = AgentWorkflowKind::kSafeDownload;
  value.id = "safe_download";
  value.title = "安全下载";
  value.purpose = "核对官方来源、平台架构、原生下载状态和完整性";
  value.tools = {"page.observe",    "page.extract",
                 "page.navigate",   "page.click",
                 "page.wait",       "tab.create",
                 "tab.activate",    "download.find_official",
                 "download.start",  "download.pause",
                 "download.resume", "download.list",
                 "download.cancel", "download.verify",
                 "download.open"};
  value.data_classes = {AgentDataClass::kPublicPage,
                        AgentDataClass::kBrowserMetadata,
                        AgentDataClass::kDownloads};
  value.budgets.max_tabs = 8;
  value.budgets.max_tool_calls = 60;
  value.budgets.max_model_calls = 20;
  value.budgets.max_network_requests = 120;
  value.budgets.max_duration = base::Hours(1);
  return value;
}

AgentWorkflowTemplate ShoppingTemplate() {
  AgentWorkflowTemplate value;
  value.kind = AgentWorkflowKind::kShopping;
  value.id = "shopping";
  value.title = "购物助手";
  value.purpose = "比较总价、配送与退货，准备结账后交还用户";
  value.tools = {
      "page.observe",       "page.extract", "page.navigate",
      "page.click",         "page.select",  "page.scroll",
      "page.wait",          "tab.create",   "tab.activate",
      "auth.attempt_login", "form.fill",    "shopping.prepare_checkout",
      "monitor.create",     "monitor.list", "monitor.pause",
      "monitor.delete"};
  value.data_classes = {AgentDataClass::kPublicPage,
                        AgentDataClass::kBrowserMetadata,
                        AgentDataClass::kFormData};
  value.budgets.max_tabs = 10;
  value.budgets.max_tool_calls = 80;
  value.budgets.max_model_calls = 30;
  value.budgets.max_network_requests = 140;
  value.budgets.max_duration = base::Minutes(45);
  value.supports_monitoring = true;
  value.always_user_takeover_for_final_action = true;
  return value;
}

}  // namespace

const AgentWorkflowTemplate& GetAgentWorkflowTemplate(AgentWorkflowKind kind) {
  static const base::NoDestructor<AgentWorkflowTemplate> research(
      ResearchTemplate());
  static const base::NoDestructor<AgentWorkflowTemplate> browser_steward(
      BrowserStewardTemplate());
  static const base::NoDestructor<AgentWorkflowTemplate> safe_download(
      SafeDownloadTemplate());
  static const base::NoDestructor<AgentWorkflowTemplate> shopping(
      ShoppingTemplate());
  switch (kind) {
    case AgentWorkflowKind::kResearch:
      return *research;
    case AgentWorkflowKind::kBrowserSteward:
      return *browser_steward;
    case AgentWorkflowKind::kSafeDownload:
      return *safe_download;
    case AgentWorkflowKind::kShopping:
      return *shopping;
  }
}

std::optional<AgentTaskScope> BuildAgentWorkflowScope(
    AgentWorkflowKind kind,
    std::vector<url::Origin> origins,
    base::flat_set<int32_t> tab_ids,
    AgentModelDestination destination) {
  const AgentWorkflowTemplate& workflow = GetAgentWorkflowTemplate(kind);
  AgentTaskScope scope;
  scope.allowed_origins = std::move(origins);
  scope.allowed_tab_ids = std::move(tab_ids);
  scope.allowed_tools = workflow.tools;
  scope.allowed_data_classes = workflow.data_classes;
  scope.budgets = workflow.budgets;
  scope.model_destination = std::move(destination);
  return scope.IsValid() ? std::make_optional(std::move(scope)) : std::nullopt;
}

}  // namespace aegis::agent
