// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_tool_registry.h"

#include <array>
#include <initializer_list>
#include <string>
#include <utility>

namespace aegis::agent {

namespace {

constexpr std::array<AgentToolDescriptor, 49> kTools = {{
    {"page.observe", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kPublicPage,
     true, false, false, false},
    {"page.extract", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kPublicPage,
     true, true, false, false},
    {"page.webmcp.list", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kPublicPage, true, true, false, false},
    {"page.webmcp.invoke", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"page.navigate", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kPublicPage, true, false, false, false},
    {"page.click", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kPublicPage, true, true, false, false},
    {"page.type", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"page.select", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"page.scroll", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kPublicPage,
     true, true, false, false},
    {"page.drag", AgentRiskLevel::kR1Reversible, AgentDataClass::kFormData,
     true, true, false, false},
    {"page.wait", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kPublicPage,
     true, true, false, false},
    {"page.history", AgentRiskLevel::kR1Reversible, AgentDataClass::kPublicPage,
     true, true, false, false},
    {"page.media", AgentRiskLevel::kR1Reversible, AgentDataClass::kPublicPage,
     true, true, false, false},
    {"page.save_pdf", AgentRiskLevel::kR3UserTakeover,
     AgentDataClass::kDownloads, true, true, true, false},
    {"auth.attempt_login", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"auth.fill_otp", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"form.fill", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kFormData, true, true, true, false},
    {"file.upload", AgentRiskLevel::kR3UserTakeover, AgentDataClass::kFormData,
     true, true, true, false},
    {"tab.list", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kBrowserMetadata,
     false, false, false, false},
    {"tab.create", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, true, false, false, true},
    {"tab.activate", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBrowserMetadata, false, false, false, false},
    {"tab.close", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, true},
    {"tab.group", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, true},
    {"window.list", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBrowserMetadata, false, false, false, false},
    {"window.create", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, true, false, false, true},
    {"window.activate", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBrowserMetadata, false, false, false, false},
    {"window.close", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kBrowserMetadata, false, false, true, false},
    {"workspace.save", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, true},
    {"workspace.restore", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, true},
    {"bookmark.list", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kBookmarks,
     false, false, false, false},
    {"bookmark.plan", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kBookmarks,
     false, false, false, false},
    {"bookmark.check_urls", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBookmarks, false, false, false, false},
    {"bookmark.apply", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kBookmarks, false, false, true, true},
    {"bookmark.undo", AgentRiskLevel::kR1Reversible, AgentDataClass::kBookmarks,
     false, false, false, true},
    {"history.search", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kHistory,
     false, false, false, false},
    {"download.find_official", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kPublicPage, true, false, false, false},
    {"download.start", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kDownloads, true, true, true, false},
    {"download.pause", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kDownloads, false, false, false, false},
    {"download.resume", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kDownloads, false, false, false, false},
    {"download.list", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kDownloads,
     false, false, false, false},
    {"download.cancel", AgentRiskLevel::kR2ExternalSideEffect,
     AgentDataClass::kDownloads, false, false, true, false},
    {"download.verify", AgentRiskLevel::kR0ReadOnly, AgentDataClass::kDownloads,
     false, false, false, false},
    {"download.open", AgentRiskLevel::kR3UserTakeover,
     AgentDataClass::kDownloads, false, false, true, false},
    {"permissions.inspect", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBrowserMetadata, true, true, false, false},
    {"monitor.create", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kPublicPage, true, true, false, true},
    {"monitor.list", AgentRiskLevel::kR0ReadOnly,
     AgentDataClass::kBrowserMetadata, false, false, false, false},
    {"monitor.pause", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, true},
    {"monitor.delete", AgentRiskLevel::kR1Reversible,
     AgentDataClass::kBrowserMetadata, false, false, false, false},
    {"shopping.prepare_checkout", AgentRiskLevel::kR3UserTakeover,
     AgentDataClass::kFormData, true, true, true, false},
}};

base::DictValue StringSchema(int max_length) {
  base::DictValue schema;
  schema.Set("type", "string");
  schema.Set("minLength", 1);
  schema.Set("maxLength", max_length);
  return schema;
}

base::DictValue IntegerSchema(int minimum, int maximum) {
  base::DictValue schema;
  schema.Set("type", "integer");
  schema.Set("minimum", minimum);
  schema.Set("maximum", maximum);
  return schema;
}

base::DictValue BooleanSchema() {
  base::DictValue schema;
  schema.Set("type", "boolean");
  return schema;
}

base::DictValue EnumSchema(std::initializer_list<std::string_view> values) {
  base::DictValue schema = StringSchema(64);
  base::ListValue choices;
  for (std::string_view value : values) {
    choices.Append(value);
  }
  schema.Set("enum", std::move(choices));
  return schema;
}

base::DictValue IntegerArraySchema(int minimum, int maximum, int max_items) {
  base::DictValue schema;
  schema.Set("type", "array");
  schema.Set("items", IntegerSchema(minimum, maximum));
  schema.Set("maxItems", max_items);
  return schema;
}

base::DictValue StringArraySchema(int max_length, int max_items) {
  base::DictValue schema;
  schema.Set("type", "array");
  schema.Set("items", StringSchema(max_length));
  schema.Set("maxItems", max_items);
  return schema;
}

base::DictValue StrictObject(base::DictValue properties,
                             std::initializer_list<std::string_view> required) {
  base::DictValue schema;
  schema.Set("type", "object");
  schema.Set("properties", std::move(properties));
  base::ListValue required_list;
  for (std::string_view value : required) {
    required_list.Append(value);
  }
  schema.Set("required", std::move(required_list));
  schema.Set("additionalProperties", false);
  return schema;
}

base::DictValue EmptySchema() {
  return StrictObject({}, {});
}

base::DictValue ToolSchema(std::string_view name) {
  base::DictValue properties;
  if (name == "page.observe") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("query", StringSchema(512));
    return StrictObject(std::move(properties), {"tab_id"});
  }
  if (name == "page.navigate" || name == "tab.create") {
    properties.Set("url", StringSchema(4096));
    if (name == "page.navigate") {
      properties.Set("tab_id", IntegerSchema(1, 1000000));
      return StrictObject(std::move(properties), {"tab_id", "url"});
    }
    return StrictObject(std::move(properties), {"url"});
  }
  if (name == "page.extract") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("kind", EnumSchema({"article", "list", "table", "product"}));
    properties.Set("fields", StringArraySchema(128, 64));
    return StrictObject(std::move(properties),
                        {"tab_id", "document_token", "kind"});
  }
  if (name == "page.webmcp.list") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    return StrictObject(std::move(properties), {"tab_id", "document_token"});
  }
  if (name == "page.webmcp.invoke") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("name", StringSchema(128));
    properties.Set("tool_revision", StringSchema(128));
    properties.Set("input_json", StringSchema(65536));
    return StrictObject(
        std::move(properties),
        {"tab_id", "document_token", "name", "tool_revision", "input_json"});
  }
  if (name == "page.click") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("node_id", IntegerSchema(1, 1000000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("button", EnumSchema({"left", "right"}));
    return StrictObject(std::move(properties),
                        {"tab_id", "node_id", "document_token"});
  }
  if (name == "page.type") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("node_id", IntegerSchema(1, 1000000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("text", StringSchema(4096));
    properties.Set("replace", BooleanSchema());
    return StrictObject(std::move(properties),
                        {"tab_id", "node_id", "document_token", "text"});
  }
  if (name == "page.select") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("node_id", IntegerSchema(1, 1000000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("value", StringSchema(1024));
    return StrictObject(std::move(properties),
                        {"tab_id", "node_id", "document_token", "value"});
  }
  if (name == "page.scroll") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("direction", EnumSchema({"up", "down", "left", "right"}));
    properties.Set("amount", IntegerSchema(1, 10000));
    return StrictObject(std::move(properties),
                        {"tab_id", "document_token", "direction", "amount"});
  }
  if (name == "page.drag") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("from_node_id", IntegerSchema(1, 1000000000));
    properties.Set("to_node_id", IntegerSchema(1, 1000000000));
    return StrictObject(std::move(properties), {"tab_id", "document_token",
                                                "from_node_id", "to_node_id"});
  }
  if (name == "page.wait") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("condition", EnumSchema({"delay"}));
    properties.Set("timeout_ms", IntegerSchema(100, 30000));
    return StrictObject(std::move(properties), {"tab_id", "document_token",
                                                "condition", "timeout_ms"});
  }
  if (name == "page.history") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("direction", EnumSchema({"back", "forward"}));
    return StrictObject(std::move(properties),
                        {"tab_id", "document_token", "direction"});
  }
  if (name == "page.media") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("action", EnumSchema({"play", "pause", "seek"}));
    properties.Set("position_ms", IntegerSchema(0, 86400000));
    return StrictObject(std::move(properties),
                        {"tab_id", "document_token", "action"});
  }
  if (name == "page.save_pdf" || name == "file.upload") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    if (name == "file.upload") {
      properties.Set("node_id", IntegerSchema(1, 1000000000));
      return StrictObject(std::move(properties),
                          {"tab_id", "document_token", "node_id"});
    }
    return StrictObject(std::move(properties), {"tab_id", "document_token"});
  }
  if (name == "auth.attempt_login") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("password_button_node_id", IntegerSchema(1, 1000000000));
    return StrictObject(std::move(properties), {"tab_id", "document_token",
                                                "password_button_node_id"});
  }
  if (name == "auth.fill_otp") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("field_node_ids", IntegerArraySchema(1, 1000000000, 8));
    properties.Set("for_signin", BooleanSchema());
    return StrictObject(
        std::move(properties),
        {"tab_id", "document_token", "field_node_ids", "for_signin"});
  }
  if (name == "form.fill") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set(
        "requested_data",
        EnumSchema({"address", "billing_address", "shipping_address",
                    "work_address", "home_address", "contact_information"}));
    properties.Set("field_node_ids", IntegerArraySchema(1, 1000000000, 32));
    properties.Set("section_label", StringSchema(256));
    return StrictObject(
        std::move(properties),
        {"tab_id", "document_token", "requested_data", "field_node_ids"});
  }
  if (name == "tab.list" || name == "bookmark.list") {
    return EmptySchema();
  }
  if (name == "tab.activate") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    return StrictObject(std::move(properties), {"tab_id"});
  }
  if (name == "tab.close") {
    properties.Set("tab_ids", IntegerArraySchema(1, 1000000, 20));
    properties.Set("revision", StringSchema(256));
    return StrictObject(std::move(properties), {"tab_ids", "revision"});
  }
  if (name == "tab.group") {
    properties.Set("tab_ids", IntegerArraySchema(1, 1000000, 20));
    properties.Set("title", StringSchema(256));
    properties.Set("color",
                   EnumSchema({"grey", "blue", "red", "yellow", "green", "pink",
                               "purple", "cyan", "orange"}));
    properties.Set("revision", StringSchema(256));
    return StrictObject(std::move(properties), {"tab_ids", "revision"});
  }
  if (name == "window.list") {
    return EmptySchema();
  }
  if (name == "window.create") {
    properties.Set("url", StringSchema(4096));
    return StrictObject(std::move(properties), {"url"});
  }
  if (name == "window.activate") {
    properties.Set("window_id", IntegerSchema(1, 1000000));
    return StrictObject(std::move(properties), {"window_id"});
  }
  if (name == "window.close") {
    properties.Set("window_id", IntegerSchema(1, 1000000));
    properties.Set("revision", StringSchema(128));
    return StrictObject(std::move(properties), {"window_id", "revision"});
  }
  if (name == "workspace.save") {
    properties.Set("name", StringSchema(128));
    properties.Set("revision", StringSchema(128));
    return StrictObject(std::move(properties), {"name", "revision"});
  }
  if (name == "workspace.restore") {
    properties.Set("workspace_id", StringSchema(128));
    properties.Set("workspace_revision", StringSchema(128));
    return StrictObject(std::move(properties),
                        {"workspace_id", "workspace_revision"});
  }
  if (name == "bookmark.plan") {
    properties.Set("strategy",
                   EnumSchema({"topic", "domain", "project", "minimal"}));
    return StrictObject(std::move(properties), {"strategy"});
  }
  if (name == "bookmark.check_urls") {
    properties.Set("node_ids", StringArraySchema(128, 100));
    return StrictObject(std::move(properties), {"node_ids"});
  }
  if (name == "bookmark.apply") {
    properties.Set("plan_id", StringSchema(128));
    properties.Set("snapshot_hash", StringSchema(128));
    return StrictObject(std::move(properties), {"plan_id", "snapshot_hash"});
  }
  if (name == "bookmark.undo") {
    properties.Set("undo_token", StringSchema(128));
    return StrictObject(std::move(properties), {"undo_token"});
  }
  if (name == "history.search") {
    properties.Set("query", StringSchema(512));
    properties.Set("domain", StringSchema(256));
    properties.Set("days", IntegerSchema(1, 3650));
    properties.Set("max_results", IntegerSchema(1, 100));
    return StrictObject(std::move(properties),
                        {"query", "days", "max_results"});
  }
  if (name == "download.find_official") {
    properties.Set("product", StringSchema(512));
    properties.Set("platform", StringSchema(64));
    properties.Set("architecture", StringSchema(64));
    properties.Set("candidate_url", StringSchema(4096));
    return StrictObject(
        std::move(properties),
        {"product", "platform", "architecture", "candidate_url"});
  }
  if (name == "download.start") {
    properties.Set("url", StringSchema(4096));
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("expected_sha256", StringSchema(64));
    return StrictObject(std::move(properties),
                        {"url", "tab_id", "document_token"});
  }
  if (name == "download.list") {
    return EmptySchema();
  }
  if (name == "download.pause" || name == "download.resume" ||
      name == "download.cancel" || name == "download.verify" ||
      name == "download.open") {
    properties.Set("download_id", StringSchema(128));
    return StrictObject(std::move(properties), {"download_id"});
  }
  if (name == "permissions.inspect") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    return StrictObject(std::move(properties), {"tab_id", "document_token"});
  }
  if (name == "monitor.create") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("kind", EnumSchema({"price", "inventory", "page_change",
                                       "url_status"}));
    properties.Set("interval_minutes", IntegerSchema(15, 10080));
    return StrictObject(std::move(properties), {"tab_id", "document_token",
                                                "kind", "interval_minutes"});
  }
  if (name == "monitor.list") {
    return EmptySchema();
  }
  if (name == "monitor.pause") {
    properties.Set("monitor_id", StringSchema(128));
    properties.Set("paused", BooleanSchema());
    return StrictObject(std::move(properties), {"monitor_id", "paused"});
  }
  if (name == "monitor.delete") {
    properties.Set("monitor_id", StringSchema(128));
    return StrictObject(std::move(properties), {"monitor_id"});
  }
  if (name == "shopping.prepare_checkout") {
    properties.Set("tab_id", IntegerSchema(1, 1000000));
    properties.Set("document_token", StringSchema(256));
    properties.Set("merchant", StringSchema(512));
    properties.Set("product", StringSchema(1024));
    properties.Set("quantity", IntegerSchema(1, 100));
    properties.Set("unit_price_minor_units", IntegerSchema(0, 1000000000));
    properties.Set("shipping_minor_units", IntegerSchema(0, 1000000000));
    properties.Set("tax_minor_units", IntegerSchema(0, 1000000000));
    properties.Set("discount_minor_units", IntegerSchema(0, 1000000000));
    properties.Set("total_minor_units", IntegerSchema(0, 1000000000));
    properties.Set("currency", StringSchema(3));
    properties.Set("delivery_summary", StringSchema(1024));
    properties.Set("return_summary", StringSchema(1024));
    properties.Set("source_node_ids", IntegerArraySchema(1, 1000000000, 1));
    properties.Set("observation_fingerprint", StringSchema(64));
    return StrictObject(
        std::move(properties),
        {"tab_id", "document_token", "merchant", "product", "quantity",
         "unit_price_minor_units", "shipping_minor_units", "tax_minor_units",
         "discount_minor_units", "total_minor_units", "currency",
         "delivery_summary", "return_summary", "source_node_ids",
         "observation_fingerprint"});
  }
  return {};
}

std::string_view ToolDescription(std::string_view name) {
  if (name == "page.observe") {
    return "Read a bounded view of an approved page.";
  }
  if (name == "page.extract") {
    return "Extract bounded fields with source nodes from an observed page.";
  }
  if (name == "page.webmcp.list") {
    return "List strict same-document WebMCP tools as untrusted page data.";
  }
  if (name == "page.webmcp.invoke") {
    return "Invoke one exact approved WebMCP tool and re-observe the page.";
  }
  if (name == "page.navigate") {
    return "Navigate an approved tab to an approved URL.";
  }
  if (name == "page.click") {
    return "Click a document-bound semantic node.";
  }
  if (name == "page.type") {
    return "Type non-secret text into an approved field.";
  }
  if (name == "page.select") {
    return "Select a value in an approved control.";
  }
  if (name == "page.scroll") {
    return "Scroll an approved document.";
  }
  if (name == "page.drag") {
    return "Drag between two document-bound semantic nodes.";
  }
  if (name == "page.wait") {
    return "Wait for a bounded delay before observing again.";
  }
  if (name == "page.history") {
    return "Traverse approved tab history and re-observe.";
  }
  if (name == "page.media") {
    return "Control playback without extracting protected media.";
  }
  if (name == "page.save_pdf") {
    return "Hand off to Chromium's standard print and save UI.";
  }
  if (name == "auth.attempt_login") {
    return "Ask Chromium password manager to attempt login without exposing "
           "credentials.";
  }
  if (name == "auth.fill_otp") {
    return "Ask Chromium to fill an available OTP without exposing its value.";
  }
  if (name == "form.fill") {
    return "Ask Chromium Autofill to fill approved non-payment data.";
  }
  if (name == "file.upload") {
    return "Hand off to the standard file picker for one explicit upload.";
  }
  if (name == "tab.list") {
    return "List task-visible browser tabs.";
  }
  if (name == "tab.create") {
    return "Create a tab at an approved URL.";
  }
  if (name == "tab.activate") {
    return "Activate a task-visible tab.";
  }
  if (name == "tab.close") {
    return "Close approved tabs at an exact revision.";
  }
  if (name == "tab.group") {
    return "Group approved tabs at an exact revision.";
  }
  if (name == "window.list") {
    return "List normal windows containing task-visible tabs.";
  }
  if (name == "window.create") {
    return "Create a normal window at an approved URL.";
  }
  if (name == "window.activate") {
    return "Activate a task-visible normal window.";
  }
  if (name == "window.close") {
    return "Close a fully task-owned window at an exact revision.";
  }
  if (name == "workspace.save") {
    return "Save sanitized task-visible tab metadata as a local workspace.";
  }
  if (name == "workspace.restore") {
    return "Restore an exact local workspace within the task tab budget.";
  }
  if (name == "bookmark.list") {
    return "List approved bookmark metadata.";
  }
  if (name == "bookmark.plan") {
    return "Create a dry-run bookmark organization plan.";
  }
  if (name == "bookmark.check_urls") {
    return "Check bounded bookmark URL availability.";
  }
  if (name == "bookmark.apply") {
    return "Apply an approved bookmark plan with undo.";
  }
  if (name == "bookmark.undo") {
    return "Undo one Aegis bookmark transaction.";
  }
  if (name == "history.search") {
    return "Search approved origins in local browser history.";
  }
  if (name == "download.find_official") {
    return "Find evidence for official download sources.";
  }
  if (name == "download.start") {
    return "Start a user-approved browser download.";
  }
  if (name == "download.pause") {
    return "Pause an Agent-owned download.";
  }
  if (name == "download.resume") {
    return "Resume an Agent-owned download.";
  }
  if (name == "download.list") {
    return "List downloads owned by this task.";
  }
  if (name == "download.cancel") {
    return "Cancel an exact Agent-owned download.";
  }
  if (name == "download.verify") {
    return "Verify a completed download's evidence.";
  }
  if (name == "download.open") {
    return "Hand a verified Agent-owned download to the user to open.";
  }
  if (name == "permissions.inspect") {
    return "Inspect selected permission settings for the current origin.";
  }
  if (name == "monitor.create") {
    return "Create a browser-lifetime read-only monitor for the exact observed "
           "page; the target is stored encrypted.";
  }
  if (name == "monitor.list") {
    return "List this task's monitors without revealing target paths.";
  }
  if (name == "monitor.pause") {
    return "Pause or resume one exact task-owned monitor.";
  }
  if (name == "monitor.delete") {
    return "Delete one exact task-owned monitor.";
  }
  if (name == "shopping.prepare_checkout") {
    return "Present a single-source checkout summary and hand final control "
           "to the user. Never submit the purchase.";
  }
  return {};
}

}  // namespace

AgentToolRegistry::AgentToolRegistry() = default;
AgentToolRegistry::~AgentToolRegistry() = default;

const AgentToolDescriptor* AgentToolRegistry::Find(
    std::string_view name) const {
  for (const AgentToolDescriptor& descriptor : kTools) {
    if (descriptor.name == name) {
      return &descriptor;
    }
  }
  return nullptr;
}

std::vector<std::string_view> AgentToolRegistry::Names() const {
  std::vector<std::string_view> names;
  names.reserve(kTools.size());
  for (const AgentToolDescriptor& descriptor : kTools) {
    names.push_back(descriptor.name);
  }
  return names;
}

std::optional<AgentModelToolDefinition> AgentToolRegistry::ModelToolForName(
    std::string_view name) const {
  const AgentToolDescriptor* descriptor = Find(name);
  if (!descriptor || descriptor->risk == AgentRiskLevel::kBlocked) {
    return std::nullopt;
  }
  AgentModelToolDefinition tool;
  tool.name = descriptor->name;
  tool.description = ToolDescription(descriptor->name);
  tool.input_schema = ToolSchema(descriptor->name);
  return tool;
}

std::vector<AgentModelToolDefinition> AgentToolRegistry::ModelToolsForScope(
    const AgentTaskScope& scope) const {
  std::vector<AgentModelToolDefinition> tools;
  tools.reserve(scope.allowed_tools.size());
  for (const AgentToolDescriptor& descriptor : kTools) {
    if (!scope.AllowsTool(std::string(descriptor.name)) ||
        descriptor.risk == AgentRiskLevel::kBlocked) {
      continue;
    }
    AgentModelToolDefinition tool;
    tool.name = descriptor.name;
    tool.description = ToolDescription(descriptor.name);
    tool.input_schema = ToolSchema(descriptor.name);
    tools.push_back(std::move(tool));
  }
  return tools;
}

}  // namespace aegis::agent
