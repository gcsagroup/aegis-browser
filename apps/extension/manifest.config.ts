import { defineManifest } from "@crxjs/vite-plugin";

export default defineManifest({
  manifest_version: 3,
  name: "GCSA-aegis",
  description:
    "Local-first privacy & security: AI assistant, phishing defense, ad/tracker blocking.",
  version: "0.1.0",
  default_locale: "zh_CN",
  icons: {
    "16": "icons/icon16.png",
    "48": "icons/icon48.png",
    "128": "icons/icon128.png",
  },
  action: {
    default_title: "GCSA-aegis",
    default_popup: "src/popup/index.html",
    default_icon: {
      "16": "icons/icon16.png",
      "48": "icons/icon48.png",
    },
  },
  background: {
    service_worker: "src/background/service-worker.ts",
    type: "module",
  },
  options_ui: {
    page: "src/options/index.html",
    open_in_tab: true,
  },
  side_panel: {
    default_path: "src/sidepanel/index.html",
  },
  permissions: [
    "storage",
    "tabs",
    "webNavigation",
    "declarativeNetRequest",
    "declarativeNetRequestFeedback",
    "sidePanel",
    "scripting",
    "cookies",
    "alarms",
  ],
  host_permissions: ["<all_urls>", "http://127.0.0.1:11434/*"],
  content_scripts: [
    {
      matches: ["http://*/*", "https://*/*"],
      js: ["src/content/main.ts"],
      run_at: "document_idle",
    },
  ],
  web_accessible_resources: [
    {
      resources: ["src/blocked/index.html", "icons/*"],
      matches: ["<all_urls>"],
    },
  ],
  declarative_net_request: {
    rule_resources: [
      {
        id: "aegis_static_rules",
        enabled: true,
        path: "rules/static.json",
      },
    ],
  },
});
