// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_browser_tools.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <map>
#include <optional>
#include <set>
#include <string_view>
#include <utility>

#include "base/check.h"
#include "base/containers/flat_set.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/profile_browser_collection.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/tabs/tab_group_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/undo/bookmark_undo_service_factory.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/browser/bookmark_node.h"
#include "components/bookmarks/browser/scoped_group_bookmark_actions.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_source.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "components/tab_groups/tab_group_color.h"
#include "components/tab_groups/tab_group_info.h"
#include "components/tab_groups/tab_group_visual_data.h"
#include "components/tabs/public/tab_group.h"
#include "components/tabs/public/tab_handle_factory.h"
#include "components/tabs/public/tab_interface.h"
#include "components/undo/bookmark_undo_service.h"
#include "components/undo/undo_manager.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/storage_partition.h"
#include "crypto/sha2.h"
#include "net/base/ip_address.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/base/url_util.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/ip_address_space_util.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "services/network/public/mojom/ip_address_space.mojom.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "ui/base/base_window.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {
namespace {

constexpr size_t kMaxReturnedTabs = 20;
constexpr size_t kMaxReturnedBookmarks = 2000;
constexpr size_t kMaxBookmarkMoves = 2000;
constexpr size_t kMaxUrlChecksPerCall = 100;
constexpr size_t kMaxConcurrentUrlChecks = 4;
constexpr size_t kMaxUrlCheckRedirects = 5;
constexpr size_t kMaxReturnedTextBytes = 2048;

AgentToolResult ErrorResult(std::string action_id,
                            AgentErrorCode error,
                            std::string message) {
  return {.action_id = std::move(action_id),
          .ok = false,
          .error = error,
          .message = std::move(message)};
}

AgentToolResult SuccessResult(std::string action_id, std::string message) {
  return {.action_id = std::move(action_id),
          .ok = true,
          .error = AgentErrorCode::kNone,
          .message = std::move(message)};
}

std::string Hash(std::string_view material) {
  return base::HexEncode(crypto::SHA256HashString(material));
}

std::string BoundedUtf8(std::string_view text) {
  return std::string(base::TruncateUTF8ToByteSize(text, kMaxReturnedTextBytes));
}

std::string SafeUrlForModel(const GURL& url) {
  if (!url.is_valid()) {
    return {};
  }
  GURL::Replacements replacements;
  replacements.ClearUsername();
  replacements.ClearPassword();
  replacements.ClearQuery();
  replacements.ClearRef();
  return BoundedUtf8(url.ReplaceComponents(replacements).spec());
}

bool HostMatchesDomain(std::string_view host, std::string_view domain) {
  if (domain.empty()) {
    return true;
  }
  return host == domain ||
         base::EndsWith(host, std::string(".") + std::string(domain),
                        base::CompareCase::SENSITIVE);
}

struct LocatedTab {
  raw_ptr<tabs::TabInterface> tab = nullptr;
  raw_ptr<BrowserWindowInterface> browser = nullptr;
  raw_ptr<TabStripModel> model = nullptr;
  int index = TabStripModel::kNoTab;
};

std::optional<LocatedTab> FindTab(Profile* profile, int32_t tab_id) {
  tabs::TabInterface* tab = tabs::TabHandle(tab_id).Get();
  if (!tab || tab->GetProfile() != profile) {
    return std::nullopt;
  }
  BrowserWindowInterface* browser = tab->GetBrowserWindowInterface();
  if (!browser || browser->GetProfile() != profile ||
      browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
      browser->IsDeleteScheduled()) {
    return std::nullopt;
  }
  TabStripModel* model = browser->GetTabStripModel();
  const int index = model ? model->GetIndexOfTab(tab) : TabStripModel::kNoTab;
  if (!model || index == TabStripModel::kNoTab) {
    return std::nullopt;
  }
  return LocatedTab{
      .tab = tab, .browser = browser, .model = model, .index = index};
}

std::vector<LocatedTab> TaskTabs(Profile* profile, const AgentTask& task) {
  std::vector<LocatedTab> tabs;
  ProfileBrowserCollection::GetForProfile(profile)->ForEach(
      [&](BrowserWindowInterface* browser) {
        if (!browser ||
            browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
            browser->IsDeleteScheduled()) {
          return true;
        }
        TabStripModel* model = browser->GetTabStripModel();
        if (!model) {
          return true;
        }
        for (int index = 0; index < model->count(); ++index) {
          tabs::TabInterface* tab = model->GetTabAtIndex(index);
          if (tab && task.AllowsTab(tab->GetHandle().raw_value())) {
            tabs.push_back(LocatedTab{.tab = tab,
                                      .browser = browser,
                                      .model = model,
                                      .index = index});
          }
        }
        return tabs.size() < kMaxReturnedTabs;
      });
  return tabs;
}

std::vector<BrowserWindowInterface*> TaskWindows(Profile* profile,
                                                 const AgentTask& task) {
  std::vector<BrowserWindowInterface*> windows;
  ProfileBrowserCollection::GetForProfile(profile)->ForEach(
      [&](BrowserWindowInterface* browser) {
        if (!browser ||
            browser->GetType() != BrowserWindowInterface::TYPE_NORMAL ||
            browser->IsDeleteScheduled()) {
          return true;
        }
        TabStripModel* model = browser->GetTabStripModel();
        for (int index = 0; model && index < model->count(); ++index) {
          tabs::TabInterface* tab = model->GetTabAtIndex(index);
          if (tab && task.AllowsTab(tab->GetHandle().raw_value())) {
            windows.push_back(browser);
            break;
          }
        }
        return true;
      });
  return windows;
}

BrowserWindowInterface* FindTaskWindow(Profile* profile,
                                       const AgentTask& task,
                                       int window_id) {
  for (BrowserWindowInterface* browser : TaskWindows(profile, task)) {
    if (browser->GetSessionID().id() == window_id) {
      return browser;
    }
  }
  return nullptr;
}

size_t NormalWindowCount(Profile* profile) {
  size_t count = 0;
  ProfileBrowserCollection::GetForProfile(profile)->ForEach(
      [&count](BrowserWindowInterface* browser) {
        if (browser &&
            browser->GetType() == BrowserWindowInterface::TYPE_NORMAL &&
            !browser->IsDeleteScheduled()) {
          ++count;
        }
        return true;
      });
  return count;
}

std::string WindowRevision(Profile* profile, const AgentTask& task) {
  std::string material;
  for (BrowserWindowInterface* browser : TaskWindows(profile, task)) {
    material.append(std::to_string(browser->GetSessionID().id()));
    material.push_back('\n');
    material.append(browser->IsActive() ? "active" : "inactive");
    material.push_back('\n');
    TabStripModel* model = browser->GetTabStripModel();
    for (int index = 0; model && index < model->count(); ++index) {
      tabs::TabInterface* tab = model->GetTabAtIndex(index);
      if (!tab || !task.AllowsTab(tab->GetHandle().raw_value())) {
        continue;
      }
      material.append(std::to_string(tab->GetHandle().raw_value()));
      material.push_back(':');
      material.append(tab->GetURL().spec());
      material.push_back(':');
      material.append(model->IsTabPinned(index) ? "pinned" : "unpinned");
      material.push_back('\n');
    }
  }
  return Hash(material);
}

bool HasActiveDownload(Profile* profile) {
  content::DownloadManager* manager = profile->GetDownloadManager();
  if (!manager) {
    return false;
  }
  content::DownloadManager::DownloadVector downloads;
  manager->GetAllDownloads(&downloads);
  return std::ranges::any_of(downloads, [](download::DownloadItem* item) {
    return item && item->GetState() == download::DownloadItem::IN_PROGRESS;
  });
}

const char* ContentSettingString(ContentSetting setting) {
  switch (setting) {
    case CONTENT_SETTING_ALLOW:
      return "allow";
    case CONTENT_SETTING_BLOCK:
      return "block";
    case CONTENT_SETTING_ASK:
      return "ask";
    case CONTENT_SETTING_SESSION_ONLY:
      return "session_only";
    case CONTENT_SETTING_DEFAULT:
      return "default";
    case CONTENT_SETTING_NUM_SETTINGS:
      return "unknown";
  }
}

std::string TabRevision(Profile* profile, const AgentTask& task) {
  std::string material;
  for (const LocatedTab& located : TaskTabs(profile, task)) {
    material.append(std::to_string(located.tab->GetHandle().raw_value()));
    material.push_back('\n');
    material.append(located.tab->GetURL().spec());
    material.push_back('\n');
    material.append(base::UTF16ToUTF8(located.tab->GetTitle()));
    material.push_back('\n');
    material.append(std::to_string(located.browser->GetSessionID().id()));
    material.push_back('\n');
    if (std::optional<tab_groups::TabGroupId> group =
            located.model->GetTabGroupForTab(located.index)) {
      material.append(group->ToString());
    }
    material.push_back('\n');
  }
  return Hash(material);
}

tab_groups::TabGroupColorId ParseGroupColor(const std::string* color) {
  if (!color || *color == "grey") {
    return tab_groups::TabGroupColorId::kGrey;
  }
  if (*color == "blue") {
    return tab_groups::TabGroupColorId::kBlue;
  }
  if (*color == "red") {
    return tab_groups::TabGroupColorId::kRed;
  }
  if (*color == "yellow") {
    return tab_groups::TabGroupColorId::kYellow;
  }
  if (*color == "green") {
    return tab_groups::TabGroupColorId::kGreen;
  }
  if (*color == "pink") {
    return tab_groups::TabGroupColorId::kPink;
  }
  if (*color == "purple") {
    return tab_groups::TabGroupColorId::kPurple;
  }
  if (*color == "cyan") {
    return tab_groups::TabGroupColorId::kCyan;
  }
  return tab_groups::TabGroupColorId::kOrange;
}

void AppendBookmarkSnapshot(const bookmarks::BookmarkNode* node,
                            std::string* material) {
  CHECK(node);
  material->append(node->uuid().AsLowercaseString());
  material->push_back('\n');
  material->append(base::UTF16ToUTF8(node->GetTitle()));
  material->push_back('\n');
  material->append(node->is_url() ? node->url().spec() : "folder");
  material->push_back('\n');
  material->append(std::to_string(node->children().size()));
  material->push_back('\n');
  for (const auto& child : node->children()) {
    AppendBookmarkSnapshot(child.get(), material);
  }
}

std::array<const bookmarks::BookmarkNode*, 3> LocalBookmarkRoots(
    bookmarks::BookmarkModel* model) {
  return {model->bookmark_bar_node(), model->other_node(),
          model->mobile_node()};
}

std::string BookmarkSnapshot(bookmarks::BookmarkModel* model) {
  std::string material;
  for (const bookmarks::BookmarkNode* root : LocalBookmarkRoots(model)) {
    if (root) {
      AppendBookmarkSnapshot(root, &material);
    }
  }
  return Hash(material);
}

void AppendBookmarkList(const bookmarks::BookmarkNode* node,
                        std::string_view storage,
                        base::ListValue* output,
                        bool* truncated) {
  if (!node || *truncated) {
    return;
  }
  for (const auto& child : node->children()) {
    if (output->size() >= kMaxReturnedBookmarks) {
      *truncated = true;
      return;
    }
    base::DictValue value;
    value.Set("node_id",
              std::string(storage == "local" ? "local:" : "account:") +
                  child->uuid().AsLowercaseString());
    value.Set("title", BoundedUtf8(base::UTF16ToUTF8(child->GetTitle())));
    value.Set("storage", storage);
    value.Set("kind", child->is_url() ? "url" : "folder");
    if (child->is_url()) {
      value.Set("url", SafeUrlForModel(child->url()));
    }
    output->Append(std::move(value));
    if (child->is_folder()) {
      AppendBookmarkList(child.get(), storage, output, truncated);
    }
  }
}

void AppendLocalBookmarkUrls(
    const bookmarks::BookmarkNode* node,
    std::vector<const bookmarks::BookmarkNode*>* output) {
  if (!node || output->size() >= kMaxBookmarkMoves) {
    return;
  }
  for (const auto& child : node->children()) {
    if (output->size() >= kMaxBookmarkMoves) {
      return;
    }
    if (child->is_url()) {
      output->push_back(child.get());
    } else if (child->is_folder()) {
      AppendLocalBookmarkUrls(child.get(), output);
    }
  }
}

bool ContainsAny(std::string_view haystack,
                 std::initializer_list<std::string_view> needles) {
  return std::ranges::any_of(needles, [haystack](std::string_view needle) {
    return haystack.find(needle) != std::string_view::npos;
  });
}

std::u16string BookmarkCategory(const bookmarks::BookmarkNode& node,
                                std::string_view strategy) {
  const std::string host = base::ToLowerASCII(node.url().host());
  const std::string title =
      base::ToLowerASCII(base::UTF16ToUTF8(node.GetTitle()));
  const std::string searchable = host + " " + title;
  if (strategy == "minimal") {
    return u"待整理";
  }

  std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      node.url(), net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (domain.empty()) {
    domain = host;
  }
  if (strategy == "domain") {
    return base::UTF8ToUTF16(BoundedUtf8(domain.empty() ? "其他网站" : domain));
  }
  if (strategy == "project") {
    const size_t dot = domain.find('.');
    const std::string project =
        dot == std::string::npos ? domain : domain.substr(0, dot);
    return base::UTF8ToUTF16(
        BoundedUtf8(project.empty() ? "其他项目" : project));
  }
  if (ContainsAny(searchable,
                  {"github", "gitlab", "developer", "docs", "api", "code",
                   "stack", "npm", "rust", "python", "开发", "開發", "编程",
                   "編程", "代码", "代碼", "技术", "技術"})) {
    return u"开发";
  }
  if (ContainsAny(searchable, {"research", "paper", "arxiv", "journal", "研究",
                               "论文", "論文", "学术", "學術"})) {
    return u"研究";
  }
  if (ContainsAny(searchable,
                  {"course", "learn", "school", "wiki", "学习", "學習"})) {
    return u"学习";
  }
  if (ContainsAny(searchable, {"shop", "store", "amazon", "taobao", "jd.com",
                               "购物", "購物", "商城"})) {
    return u"购物";
  }
  if (ContainsAny(searchable, {"download", "release", ".dmg", ".pkg", ".zip",
                               "下载", "下載"})) {
    return u"下载";
  }
  if (ContainsAny(searchable, {"news", "headline", "press", "新闻", "新聞",
                               "资讯", "資訊"})) {
    return u"新闻";
  }
  if (ContainsAny(searchable, {"video", "music", "game", "movie", "youtube"})) {
    return u"娱乐";
  }
  if (ContainsAny(searchable, {"mail", "office", "notion", "slack", "work"})) {
    return u"工作";
  }
  return u"其他";
}

const bookmarks::BookmarkNode* FindChildFolder(
    const bookmarks::BookmarkNode* parent,
    std::u16string_view title) {
  if (!parent) {
    return nullptr;
  }
  for (const auto& child : parent->children()) {
    if (child->is_folder() && child->GetTitle() == title) {
      return child.get();
    }
  }
  return nullptr;
}

const bookmarks::BookmarkNode* GetLocalNodeByUuid(
    bookmarks::BookmarkModel* model,
    std::string_view value) {
  const base::Uuid uuid = base::Uuid::ParseLowercase(value);
  return uuid.is_valid()
             ? model->GetNodeByUuid(
                   uuid, bookmarks::BookmarkModel::NodeTypeForUuidLookup::
                             kLocalOrSyncableNodes)
             : nullptr;
}

const bookmarks::BookmarkNode* GetBookmarkNodeByExternalId(
    bookmarks::BookmarkModel* model,
    std::string_view external_id) {
  constexpr std::string_view kLocalPrefix = "local:";
  constexpr std::string_view kAccountPrefix = "account:";
  bookmarks::BookmarkModel::NodeTypeForUuidLookup lookup_type;
  std::string_view uuid_value;
  if (base::StartsWith(external_id, kLocalPrefix)) {
    lookup_type =
        bookmarks::BookmarkModel::NodeTypeForUuidLookup::kLocalOrSyncableNodes;
    uuid_value = external_id.substr(kLocalPrefix.size());
  } else if (base::StartsWith(external_id, kAccountPrefix)) {
    lookup_type =
        bookmarks::BookmarkModel::NodeTypeForUuidLookup::kAccountNodes;
    uuid_value = external_id.substr(kAccountPrefix.size());
  } else {
    return nullptr;
  }
  const base::Uuid uuid = base::Uuid::ParseLowercase(uuid_value);
  return uuid.is_valid() ? model->GetNodeByUuid(uuid, lookup_type) : nullptr;
}

std::string UrlCheckClassification(int net_error,
                                   int response_code,
                                   bool redirected) {
  if (net_error == net::ERR_TIMED_OUT) {
    return "timeout";
  }
  if (net_error == net::ERR_NAME_NOT_RESOLVED ||
      net_error == net::ERR_NAME_RESOLUTION_FAILED) {
    return "dns_error";
  }
  if (net::IsCertificateError(net_error)) {
    return "tls_error";
  }
  if (net_error != net::OK && response_code == 0) {
    return "indeterminate";
  }
  if (response_code == 401 || response_code == 403) {
    return "auth_required";
  }
  if (response_code == 429) {
    return "rate_limited";
  }
  if (response_code == 404 || response_code == 410) {
    return "permanent_http_error";
  }
  if (response_code >= 500 && response_code <= 599) {
    return "temporary_http_error";
  }
  if (response_code >= 200 && response_code <= 399) {
    return redirected ? "redirect" : "live";
  }
  return "indeterminate";
}

bool IsUrlCheckTargetAllowed(const AgentTaskScope& scope,
                             const GURL& selected_bookmark_url,
                             const GURL& target) {
  const auto is_public_target = [](const GURL& url) {
    if (!url.is_valid() || !url.SchemeIsHTTPOrHTTPS() || url.host().empty() ||
        !url.username().empty() || !url.password().empty() ||
        net::IsLocalhost(url)) {
      return false;
    }
    if (!url.HostIsIPAddress()) {
      return true;
    }
    net::IPAddress address;
    return net::ParseURLHostnameToAddress(url.host(), &address) &&
           network::IPAddressToIPAddressSpace(address) ==
               network::mojom::IPAddressSpace::kPublic;
  };
  return is_public_target(selected_bookmark_url) && is_public_target(target) &&
         (url::Origin::Create(target) ==
              url::Origin::Create(selected_bookmark_url) ||
          scope.AllowsOrigin(target));
}

bool IsSha256Hex(std::string_view value) {
  return value.size() == 64u &&
         std::ranges::all_of(value, [](unsigned char character) {
           return base::IsHexDigit(character);
         });
}

const char* DownloadStateString(download::DownloadItem::DownloadState state) {
  switch (state) {
    case download::DownloadItem::IN_PROGRESS:
      return "in_progress";
    case download::DownloadItem::COMPLETE:
      return "complete";
    case download::DownloadItem::CANCELLED:
      return "cancelled";
    case download::DownloadItem::INTERRUPTED:
      return "interrupted";
    case download::DownloadItem::MAX_DOWNLOAD_STATE:
      return "unknown";
  }
}

bool CandidateMentions(std::string_view candidate, std::string_view expected) {
  const std::string lower_candidate = base::ToLowerASCII(candidate);
  std::string token;
  for (unsigned char character : expected) {
    if (base::IsAsciiAlphaNumeric(character)) {
      token.push_back(base::ToLowerASCII(character));
      continue;
    }
    if (token.size() >= 3 && lower_candidate.contains(token)) {
      return true;
    }
    token.clear();
  }
  return token.size() >= 3 && lower_candidate.contains(token);
}

}  // namespace

bool IsAegisBookmarkUrlCheckTargetAllowed(const AgentTaskScope& scope,
                                          const GURL& selected_bookmark_url,
                                          const GURL& target) {
  return IsUrlCheckTargetAllowed(scope, selected_bookmark_url, target);
}

void CancelAegisOwnedDownloadOnTaskStop(download::DownloadItem* item) {
  if (!item) {
    return;
  }
  const download::DownloadItem::DownloadState state = item->GetState();
  if (state == download::DownloadItem::IN_PROGRESS ||
      state == download::DownloadItem::INTERRUPTED) {
    item->Cancel(/*user_cancel=*/true);
  }
}

struct AegisBrowserTools::UrlCheckBatch {
  struct Entry {
    std::string node_id;
    GURL url;
    bool use_get = false;
    bool active = false;
    bool completed = false;
    base::TimeTicks not_before;
    std::vector<GURL> redirects;
  };

  raw_ptr<AgentTask> task = nullptr;
  std::string task_id;
  std::string action_id;
  std::vector<Entry> entries;
  size_t completed = 0;
  std::vector<std::optional<base::DictValue>> results;
  std::map<size_t, std::unique_ptr<network::SimpleURLLoader>> loaders;
  base::flat_set<std::string> active_origins;
  base::OneShotTimer retry_timer;
  ToolResultCallback callback;
};

AegisBrowserTools::AegisBrowserTools(Profile* profile) : profile_(profile) {
  CHECK(profile_);
}

AegisBrowserTools::~AegisBrowserTools() {
  StopObservingBookmarkUndoManager();
}

bool AegisBrowserTools::CanHandle(std::string_view tool_name) const {
  return base::StartsWith(tool_name, "tab.") ||
         base::StartsWith(tool_name, "window.") ||
         base::StartsWith(tool_name, "workspace.") ||
         base::StartsWith(tool_name, "bookmark.") ||
         base::StartsWith(tool_name, "download.") ||
         tool_name == "history.search" || tool_name == "permissions.inspect";
}

void AegisBrowserTools::Execute(AgentTask* task,
                                const AgentToolCall& call,
                                ToolResultCallback callback) {
  if (!task || !CanHandle(call.tool_name)) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "browser tool is unavailable"));
    return;
  }
  if (base::StartsWith(call.tool_name, "tab.")) {
    ExecuteTabTool(task, call, std::move(callback));
    return;
  }
  if (base::StartsWith(call.tool_name, "bookmark.")) {
    ExecuteBookmarkTool(task, call, std::move(callback));
    return;
  }
  if (base::StartsWith(call.tool_name, "window.")) {
    ExecuteWindowTool(task, call, std::move(callback));
    return;
  }
  if (base::StartsWith(call.tool_name, "workspace.")) {
    ExecuteWorkspaceTool(task, call, std::move(callback));
    return;
  }
  if (call.tool_name == "history.search") {
    ExecuteHistoryTool(task, call, std::move(callback));
    return;
  }
  if (call.tool_name == "permissions.inspect") {
    ExecutePermissionsTool(task, call, std::move(callback));
    return;
  }
  ExecuteDownloadTool(task, call, std::move(callback));
}

void AegisBrowserTools::ForgetTask(const std::string& task_id,
                                   bool preserve_bookmark_undo,
                                   bool cancel_active_downloads) {
  history_task_tracker_.TryCancelAll();
  std::erase_if(bookmark_plans_, [&task_id](const auto& entry) {
    return entry.second.task_id == task_id;
  });
  if (!preserve_bookmark_undo) {
    std::erase_if(bookmark_undo_receipts_, [&task_id](const auto& entry) {
      return entry.second.task_id == task_id;
    });
  }
  if (bookmark_undo_receipts_.empty()) {
    StopObservingBookmarkUndoManager();
  }
  std::vector<std::pair<std::string, ToolResultCallback>> cancelled;
  for (auto it = url_check_batches_.begin(); it != url_check_batches_.end();) {
    if (it->second->task_id != task_id) {
      ++it;
      continue;
    }
    cancelled.emplace_back(it->second->action_id,
                           std::move(it->second->callback));
    it = url_check_batches_.erase(it);
  }
  for (auto& [action_id, callback] : cancelled) {
    std::move(callback).Run(ErrorResult(std::move(action_id),
                                        AgentErrorCode::kCancelled,
                                        "URL check cancelled with task"));
  }
  auto downloads = owned_downloads_.find(task_id);
  if (downloads != owned_downloads_.end()) {
    content::DownloadManager* manager =
        cancel_active_downloads ? profile_->GetDownloadManager() : nullptr;
    for (const std::string& guid : downloads->second) {
      download::DownloadItem* item =
          manager ? manager->GetDownloadByGuid(guid) : nullptr;
      CancelAegisOwnedDownloadOnTaskStop(item);
      expected_download_hashes_.erase(guid);
    }
    owned_downloads_.erase(downloads);
  }
  std::erase_if(pending_download_tasks_, [&task_id](const auto& entry) {
    return entry.second == task_id;
  });
}

void AegisBrowserTools::ObserveBookmarkUndoManager(UndoManager* undo_manager) {
  if (bookmark_undo_manager_ == undo_manager) {
    return;
  }
  StopObservingBookmarkUndoManager();
  bookmark_undo_manager_ = undo_manager;
  if (bookmark_undo_manager_) {
    bookmark_undo_manager_->AddObserver(this);
  }
}

void AegisBrowserTools::StopObservingBookmarkUndoManager() {
  if (!bookmark_undo_manager_) {
    return;
  }
  bookmark_undo_manager_->RemoveObserver(this);
  bookmark_undo_manager_ = nullptr;
}

void AegisBrowserTools::OnUndoManagerStateChange() {
  bookmark_undo_receipts_.clear();
  StopObservingBookmarkUndoManager();
}

void AegisBrowserTools::OnUndoManagerShutdown() {
  bookmark_undo_receipts_.clear();
  StopObservingBookmarkUndoManager();
}

void AegisBrowserTools::ExecuteTabTool(AgentTask* task,
                                       const AgentToolCall& call,
                                       ToolResultCallback callback) {
  if (call.tool_name == "tab.list") {
    AgentToolResult result = SuccessResult(call.action_id, "tabs listed");
    base::ListValue values;
    for (const LocatedTab& located : TaskTabs(profile_, *task)) {
      base::DictValue value;
      value.Set("tab_id", located.tab->GetHandle().raw_value());
      value.Set("title",
                BoundedUtf8(base::UTF16ToUTF8(located.tab->GetTitle())));
      value.Set("url", SafeUrlForModel(located.tab->GetURL()));
      value.Set("active", located.model->active_index() == located.index);
      if (std::optional<tab_groups::TabGroupId> group =
              located.model->GetTabGroupForTab(located.index)) {
        value.Set("group_id", group->ToString());
      }
      values.Append(std::move(value));
    }
    result.value.Set("tabs", std::move(values));
    result.value.Set("revision", TabRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "tab.create") {
    const std::string* url_value = call.arguments.FindString("url");
    const GURL url(url_value ? *url_value : std::string());
    BrowserWindowInterface* browser =
        ProfileBrowserCollection::GetForProfile(profile_)->FindTabbedBrowser();
    if (!url_value || !task->scope().AllowsOrigin(url) || !browser) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "approved target or tabbed browser is unavailable"));
      return;
    }
    NavigateParams params(browser, url, ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
    params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
    Navigate(&params);
    tabs::TabInterface* tab = params.navigated_or_inserted_contents
                                  ? tabs::TabInterface::GetFromContents(
                                        params.navigated_or_inserted_contents)
                                  : nullptr;
    const int32_t tab_id = tab ? tab->GetHandle().raw_value() : 0;
    if (!tab || tab->GetProfile() != profile_ || !task->AdoptOwnedTab(tab_id)) {
      if (tab && tab->GetProfile() == profile_) {
        tab->Close();
      }
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kBudgetExhausted,
                      "new tab could not be adopted within task budget"));
      return;
    }
    AgentToolResult result = SuccessResult(call.action_id, "tab created");
    result.value.Set("tab_id", tab_id);
    result.value.Set("url", SafeUrlForModel(url));
    result.value.Set("revision", TabRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "tab.activate") {
    const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
    std::optional<LocatedTab> located = tab_id && task->AllowsTab(*tab_id)
                                            ? FindTab(profile_, *tab_id)
                                            : std::nullopt;
    if (!located) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kScopeViolation,
                                          "task-visible tab is unavailable"));
      return;
    }
    located->model->ActivateTabAt(located->index);
    AgentToolResult result = SuccessResult(call.action_id, "tab activated");
    result.value.Set("tab_id", *tab_id);
    std::move(callback).Run(std::move(result));
    return;
  }

  const base::ListValue* tab_ids = call.arguments.FindList("tab_ids");
  const std::string* revision = call.arguments.FindString("revision");
  if (!tab_ids || tab_ids->empty() || !revision ||
      *revision != TabRevision(profile_, *task)) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kStaleDocument,
                                        "tab set changed after preview"));
    return;
  }
  base::flat_set<int32_t> unique_ids;
  std::vector<LocatedTab> located_tabs;
  for (const base::Value& value : *tab_ids) {
    const int32_t tab_id = value.GetInt();
    std::optional<LocatedTab> located =
        task->AllowsTab(tab_id) ? FindTab(profile_, tab_id) : std::nullopt;
    if (!located || !unique_ids.insert(tab_id).second) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "tab selection is unavailable or duplicated"));
      return;
    }
    located_tabs.push_back(*located);
  }

  if (call.tool_name == "tab.close") {
    std::ranges::sort(located_tabs,
                      [](const LocatedTab& left, const LocatedTab& right) {
                        if (left.model != right.model) {
                          return left.model < right.model;
                        }
                        return left.index > right.index;
                      });
    for (const LocatedTab& located : located_tabs) {
      if (!located.model->IsTabClosable(located.tab)) {
        std::move(callback).Run(
            ErrorResult(call.action_id, AgentErrorCode::kVerificationFailed,
                        "one selected tab cannot be closed"));
        return;
      }
    }
    for (const LocatedTab& located : located_tabs) {
      const int current_index = located.model->GetIndexOfTab(located.tab);
      if (current_index != TabStripModel::kNoTab) {
        located.model->CloseWebContentsAt(
            current_index, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
      }
    }
    AgentToolResult result =
        SuccessResult(call.action_id, "tab close requested");
    result.value.Set("requested", static_cast<int>(located_tabs.size()));
    result.value.Set("revision", TabRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "tab.group") {
    TabStripModel* model = located_tabs.front().model;
    if (!model->SupportsTabGroups() ||
        std::ranges::any_of(located_tabs, [model](const LocatedTab& located) {
          return located.model != model;
        })) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "selected tabs must share one group-capable window"));
      return;
    }
    std::vector<int> indices;
    for (const LocatedTab& located : located_tabs) {
      indices.push_back(located.index);
    }
    std::ranges::sort(indices);
    const tab_groups::TabGroupId group_id = model->AddToNewGroup(indices);
    const std::string* title = call.arguments.FindString("title");
    model->ChangeTabGroupVisuals(
        group_id,
        tab_groups::TabGroupVisualData(
            title ? base::UTF8ToUTF16(*title) : std::u16string(),
            ParseGroupColor(call.arguments.FindString("color")), false));
    AgentToolResult result = SuccessResult(call.action_id, "tabs grouped");
    result.value.Set("group_id", group_id.ToString());
    result.value.Set("revision", TabRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  std::move(callback).Run(ErrorResult(call.action_id,
                                      AgentErrorCode::kToolUnavailable,
                                      "tab tool is not implemented"));
}

void AegisBrowserTools::ExecuteWindowTool(AgentTask* task,
                                          const AgentToolCall& call,
                                          ToolResultCallback callback) {
  if (call.tool_name == "window.list") {
    AgentToolResult result = SuccessResult(call.action_id, "windows listed");
    base::ListValue windows;
    for (BrowserWindowInterface* browser : TaskWindows(profile_, *task)) {
      base::DictValue value;
      value.Set("window_id", browser->GetSessionID().id());
      value.Set("active", browser->IsActive());
      base::ListValue tab_ids;
      TabStripModel* model = browser->GetTabStripModel();
      for (int index = 0; model && index < model->count(); ++index) {
        tabs::TabInterface* tab = model->GetTabAtIndex(index);
        if (tab && task->AllowsTab(tab->GetHandle().raw_value())) {
          tab_ids.Append(tab->GetHandle().raw_value());
        }
      }
      value.Set("tab_ids", std::move(tab_ids));
      windows.Append(std::move(value));
    }
    result.value.Set("windows", std::move(windows));
    result.value.Set("revision", WindowRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "window.create") {
    const std::string* url_value = call.arguments.FindString("url");
    const GURL url(url_value ? *url_value : std::string());
    BrowserWindowInterface* source =
        ProfileBrowserCollection::GetForProfile(profile_)->FindTabbedBrowser();
    if (!url_value || !source || !task->scope().AllowsOrigin(url)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "approved URL or source window is unavailable"));
      return;
    }
    NavigateParams params(source, url, ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
    params.disposition = WindowOpenDisposition::NEW_WINDOW;
    Navigate(&params);
    tabs::TabInterface* tab = params.navigated_or_inserted_contents
                                  ? tabs::TabInterface::GetFromContents(
                                        params.navigated_or_inserted_contents)
                                  : nullptr;
    BrowserWindowInterface* created =
        tab ? tab->GetBrowserWindowInterface() : nullptr;
    const int32_t tab_id = tab ? tab->GetHandle().raw_value() : 0;
    if (!tab || !created || created->GetProfile() != profile_ ||
        !task->AdoptOwnedTab(tab_id)) {
      if (tab && tab->GetProfile() == profile_) {
        tab->Close();
      }
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kBudgetExhausted,
                      "new window tab could not be adopted"));
      return;
    }
    AgentToolResult result = SuccessResult(call.action_id, "window created");
    result.value.Set("window_id", created->GetSessionID().id());
    result.value.Set("tab_id", tab_id);
    result.value.Set("revision", WindowRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }

  const std::optional<int> window_id = call.arguments.FindInt("window_id");
  BrowserWindowInterface* browser =
      window_id ? FindTaskWindow(profile_, *task, *window_id) : nullptr;
  if (!browser) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kScopeViolation,
                                        "task-visible window is unavailable"));
    return;
  }
  if (call.tool_name == "window.activate") {
    browser->GetWindow()->Activate();
    AgentToolResult result = SuccessResult(call.action_id, "window activated");
    result.value.Set("window_id", *window_id);
    result.value.Set("active", true);
    std::move(callback).Run(std::move(result));
    return;
  }
  if (call.tool_name == "window.close") {
    const std::string* revision = call.arguments.FindString("revision");
    TabStripModel* model = browser->GetTabStripModel();
    if (!revision || *revision != WindowRevision(profile_, *task) || !model) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kStaleDocument,
                                          "window set changed after preview"));
      return;
    }
    if (NormalWindowCount(profile_) <= 1u || HasActiveDownload(profile_)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "last window or active download prevents close"));
      return;
    }
    for (int index = 0; index < model->count(); ++index) {
      tabs::TabInterface* tab = model->GetTabAtIndex(index);
      content::WebContents* contents = tab ? tab->GetContents() : nullptr;
      if (!tab ||
          !task->owned_tab_ids().contains(tab->GetHandle().raw_value()) ||
          model->IsTabPinned(index) ||
          (contents && contents->NeedToFireBeforeUnloadOrUnloadEvents())) {
        std::move(callback).Run(
            ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                        "window contains unowned, pinned, or unsaved tabs"));
        return;
      }
    }
    browser->GetWindow()->Close();
    AgentToolResult result =
        SuccessResult(call.action_id, "safe window close requested");
    result.value.Set("window_id", *window_id);
    result.value.Set("close_requested", true);
    std::move(callback).Run(std::move(result));
    return;
  }
  std::move(callback).Run(ErrorResult(call.action_id,
                                      AgentErrorCode::kToolUnavailable,
                                      "window tool is not implemented"));
}

void AegisBrowserTools::ExecuteWorkspaceTool(AgentTask* task,
                                             const AgentToolCall& call,
                                             ToolResultCallback callback) {
  if (call.tool_name == "workspace.save") {
    const std::string* name = call.arguments.FindString("name");
    const std::string* revision = call.arguments.FindString("revision");
    if (!name || !revision || *revision != TabRevision(profile_, *task)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "tab set changed before workspace save"));
      return;
    }
    base::ListValue tabs;
    for (const LocatedTab& located : TaskTabs(profile_, *task)) {
      base::DictValue value;
      value.Set("url", SafeUrlForModel(located.tab->GetURL()));
      value.Set("pinned", located.model->IsTabPinned(located.index));
      if (std::optional<tab_groups::TabGroupId> group_id =
              located.model->GetTabGroupForTab(located.index)) {
        TabGroup* group = located.model->group_model()->GetTabGroup(*group_id);
        if (group && group->visual_data()) {
          value.Set("group_key", group_id->ToString());
          value.Set("group_title",
                    base::UTF16ToUTF8(group->visual_data()->title()));
          value.Set("group_color", tab_groups::TabGroupColorToString(
                                       group->visual_data()->color()));
        }
      }
      tabs.Append(std::move(value));
    }
    std::string serialized;
    if (tabs.empty() || !base::JSONWriter::Write(tabs, &serialized)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "workspace has no task-visible tabs"));
      return;
    }
    const std::string workspace_id =
        base::Uuid::GenerateRandomV4().AsLowercaseString();
    const std::string workspace_revision = Hash(serialized);
    base::DictValue workspace;
    workspace.Set("name", *name);
    workspace.Set("revision", workspace_revision);
    workspace.Set("tabs", std::move(tabs));
    ScopedDictPrefUpdate update(profile_->GetPrefs(),
                                aegis::prefs::kAgentWorkspaces);
    if (update->size() >= 50u) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kBudgetExhausted,
                                          "workspace storage limit reached"));
      return;
    }
    update->Set(workspace_id, std::move(workspace));
    AgentToolResult result = SuccessResult(call.action_id, "workspace saved");
    result.value.Set("workspace_id", workspace_id);
    result.value.Set("workspace_revision", workspace_revision);
    result.value.Set("tab_count",
                     static_cast<int>(TaskTabs(profile_, *task).size()));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "workspace.restore") {
    const std::string* workspace_id = call.arguments.FindString("workspace_id");
    const std::string* requested_revision =
        call.arguments.FindString("workspace_revision");
    const base::DictValue* workspace =
        workspace_id ? profile_->GetPrefs()
                           ->GetDict(aegis::prefs::kAgentWorkspaces)
                           .FindDict(*workspace_id)
                     : nullptr;
    const std::string* stored_revision =
        workspace ? workspace->FindString("revision") : nullptr;
    const base::ListValue* tabs =
        workspace ? workspace->FindList("tabs") : nullptr;
    if (!workspace_id || !requested_revision || !stored_revision || !tabs ||
        *requested_revision != *stored_revision || tabs->empty() ||
        tabs->size() > 20u ||
        task->scope().allowed_tab_ids.size() + task->owned_tab_ids().size() +
                tabs->size() >
            static_cast<size_t>(task->scope().budgets.max_tabs)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kBudgetExhausted,
                      "workspace is stale or exceeds the task tab budget"));
      return;
    }
    BrowserWindowInterface* browser =
        ProfileBrowserCollection::GetForProfile(profile_)->FindTabbedBrowser();
    if (!browser) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kToolUnavailable,
                      "normal browser window is unavailable"));
      return;
    }
    for (const base::Value& value : *tabs) {
      const std::string* url_value = value.GetDict().FindString("url");
      if (!url_value || !task->scope().AllowsOrigin(GURL(*url_value))) {
        std::move(callback).Run(
            ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                        "workspace contains an unapproved origin"));
        return;
      }
    }

    std::vector<tabs::TabInterface*> created_tabs;
    std::map<std::string, std::vector<tabs::TabInterface*>> group_tabs;
    std::map<std::string, std::pair<std::string, std::string>> group_visuals;
    for (const base::Value& value : *tabs) {
      const base::DictValue& tab_value = value.GetDict();
      NavigateParams params(browser, GURL(*tab_value.FindString("url")),
                            ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
      params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
      Navigate(&params);
      tabs::TabInterface* tab = params.navigated_or_inserted_contents
                                    ? tabs::TabInterface::GetFromContents(
                                          params.navigated_or_inserted_contents)
                                    : nullptr;
      const int32_t tab_id = tab ? tab->GetHandle().raw_value() : 0;
      if (!tab || !task->AdoptOwnedTab(tab_id)) {
        for (tabs::TabInterface* created : created_tabs) {
          task->ReleaseOwnedTab(created->GetHandle().raw_value());
          created->Close();
        }
        if (tab) {
          tab->Close();
        }
        std::move(callback).Run(
            ErrorResult(call.action_id, AgentErrorCode::kVerificationFailed,
                        "workspace restore rolled back after tab failure"));
        return;
      }
      created_tabs.push_back(tab);
      TabStripModel* model = browser->GetTabStripModel();
      const int index = model->GetIndexOfTab(tab);
      if (tab_value.FindBool("pinned").value_or(false)) {
        model->SetTabPinned(index, true);
      }
      if (const std::string* group_key = tab_value.FindString("group_key")) {
        group_tabs[*group_key].push_back(tab);
        group_visuals[*group_key] = {tab_value.FindString("group_title")
                                         ? *tab_value.FindString("group_title")
                                         : std::string(),
                                     tab_value.FindString("group_color")
                                         ? *tab_value.FindString("group_color")
                                         : std::string("grey")};
      }
    }
    TabStripModel* model = browser->GetTabStripModel();
    for (auto& [group_key, tabs_in_group] : group_tabs) {
      std::vector<int> indices;
      for (tabs::TabInterface* tab : tabs_in_group) {
        const int index = model->GetIndexOfTab(tab);
        if (index != TabStripModel::kNoTab) {
          indices.push_back(index);
        }
      }
      if (indices.empty()) {
        continue;
      }
      std::ranges::sort(indices);
      const tab_groups::TabGroupId group_id = model->AddToNewGroup(indices);
      const auto& visual = group_visuals[group_key];
      model->ChangeTabGroupVisuals(group_id,
                                   tab_groups::TabGroupVisualData(
                                       base::UTF8ToUTF16(visual.first),
                                       ParseGroupColor(&visual.second), false));
    }
    AgentToolResult result =
        SuccessResult(call.action_id, "workspace restored");
    base::ListValue tab_ids;
    for (tabs::TabInterface* tab : created_tabs) {
      tab_ids.Append(tab->GetHandle().raw_value());
    }
    result.value.Set("tab_ids", std::move(tab_ids));
    result.value.Set("workspace_revision", *stored_revision);
    result.value.Set("revision", TabRevision(profile_, *task));
    std::move(callback).Run(std::move(result));
    return;
  }
  std::move(callback).Run(ErrorResult(call.action_id,
                                      AgentErrorCode::kToolUnavailable,
                                      "workspace tool is not implemented"));
}

void AegisBrowserTools::ExecuteHistoryTool(AgentTask* task,
                                           const AgentToolCall& call,
                                           ToolResultCallback callback) {
  history::HistoryService* service = HistoryServiceFactory::GetForProfile(
      profile_, ServiceAccessType::EXPLICIT_ACCESS);
  const std::string* query = call.arguments.FindString("query");
  const std::string* domain = call.arguments.FindString("domain");
  const std::optional<int> days = call.arguments.FindInt("days");
  const std::optional<int> max_results = call.arguments.FindInt("max_results");
  if (!service || !query || !days || !max_results) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kToolUnavailable,
                    "history service or query is unavailable"));
    return;
  }
  history::QueryOptions options;
  options.SetRecentDayRange(*days);
  options.max_count = *max_results;
  options.policy_for_404_visits = history::VisitQuery404sPolicy::kExclude404s;
  options.include_actor_visits = true;
  service->QueryHistory(
      base::UTF8ToUTF16(*query), options,
      base::BindOnce(&AegisBrowserTools::OnHistorySearch,
                     weak_ptr_factory_.GetWeakPtr(), task->scope(),
                     call.action_id, domain ? *domain : std::string(),
                     std::move(callback)),
      &history_task_tracker_);
}

void AegisBrowserTools::OnHistorySearch(AgentTaskScope scope,
                                        std::string action_id,
                                        std::string domain,
                                        ToolResultCallback callback,
                                        history::QueryResults results) {
  AgentToolResult result =
      SuccessResult(std::move(action_id), "approved history results listed");
  base::ListValue values;
  const std::string requested_domain = base::ToLowerASCII(domain);
  for (const history::URLResult& item : results) {
    if (!scope.AllowsOrigin(item.url()) ||
        !HostMatchesDomain(base::ToLowerASCII(item.url().host()),
                           requested_domain)) {
      continue;
    }
    base::DictValue value;
    value.Set("url", SafeUrlForModel(item.url()));
    value.Set("title", BoundedUtf8(base::UTF16ToUTF8(item.title())));
    value.Set(
        "last_visit_ms",
        base::NumberToString(item.last_visit().InMillisecondsSinceUnixEpoch()));
    value.Set("visit_count", item.visit_count());
    values.Append(std::move(value));
  }
  result.value.Set("results", std::move(values));
  std::move(callback).Run(std::move(result));
}

void AegisBrowserTools::ExecutePermissionsTool(AgentTask* task,
                                               const AgentToolCall& call,
                                               ToolResultCallback callback) {
  const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
  std::optional<LocatedTab> located = tab_id && task->AllowsTab(*tab_id)
                                          ? FindTab(profile_, *tab_id)
                                          : std::nullopt;
  if (!located || located->tab->GetURL() != call.committed_url ||
      !task->scope().AllowsOrigin(call.committed_url)) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                    "permission origin changed after observation"));
    return;
  }
  HostContentSettingsMap* settings =
      HostContentSettingsMapFactory::GetForProfile(profile_);
  if (!settings) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kToolUnavailable,
                    "content settings service is unavailable"));
    return;
  }
  constexpr std::array<std::pair<std::string_view, ContentSettingsType>, 7>
      kPermissionTypes = {
          {{"cookies", ContentSettingsType::COOKIES},
           {"location", ContentSettingsType::GEOLOCATION},
           {"notifications", ContentSettingsType::NOTIFICATIONS},
           {"camera", ContentSettingsType::MEDIASTREAM_CAMERA},
           {"microphone", ContentSettingsType::MEDIASTREAM_MIC},
           {"popups", ContentSettingsType::POPUPS},
           {"clipboard", ContentSettingsType::CLIPBOARD_READ_WRITE}}};
  AgentToolResult result =
      SuccessResult(call.action_id, "site permissions inspected");
  result.value.Set("origin",
                   url::Origin::Create(call.committed_url).Serialize());
  base::DictValue permissions;
  for (const auto& [name, type] : kPermissionTypes) {
    permissions.Set(name, ContentSettingString(settings->GetContentSetting(
                              call.committed_url, call.committed_url, type)));
  }
  result.value.Set("permissions", std::move(permissions));
  std::move(callback).Run(std::move(result));
}

void AegisBrowserTools::ExecuteBookmarkTool(AgentTask* task,
                                            const AgentToolCall& call,
                                            ToolResultCallback callback) {
  bookmarks::BookmarkModel* model =
      BookmarkModelFactory::GetForBrowserContext(profile_);
  if (!model || !model->loaded()) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "bookmark model is not ready"));
    return;
  }

  if (call.tool_name == "bookmark.list") {
    AgentToolResult result =
        SuccessResult(call.action_id, "bookmark metadata listed");
    base::ListValue nodes;
    bool truncated = false;
    for (const bookmarks::BookmarkNode* root : LocalBookmarkRoots(model)) {
      AppendBookmarkList(root, "local", &nodes, &truncated);
    }
    const std::array<const bookmarks::BookmarkNode*, 3> account_roots = {
        model->account_bookmark_bar_node(), model->account_other_node(),
        model->account_mobile_node()};
    for (const bookmarks::BookmarkNode* root : account_roots) {
      AppendBookmarkList(root, "account_read_only", &nodes, &truncated);
    }
    result.value.Set("nodes", std::move(nodes));
    result.value.Set("truncated", truncated);
    result.value.Set("snapshot_hash", BookmarkSnapshot(model));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "bookmark.plan") {
    const std::string* strategy = call.arguments.FindString("strategy");
    if (!strategy) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kInvalidRequest,
                                          "bookmark strategy is missing"));
      return;
    }
    BookmarkPlan plan;
    plan.task_id = task->id();
    plan.plan_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    plan.snapshot_hash = BookmarkSnapshot(model);
    base::ListValue preview;
    std::vector<const bookmarks::BookmarkNode*> local_urls;
    for (const bookmarks::BookmarkNode* root : LocalBookmarkRoots(model)) {
      AppendLocalBookmarkUrls(root, &local_urls);
    }
    for (const bookmarks::BookmarkNode* node : local_urls) {
      const std::u16string category = BookmarkCategory(*node, *strategy);
      plan.moves.push_back(BookmarkMove{
          .node_uuid = node->uuid().AsLowercaseString(), .category = category});
      base::DictValue move;
      move.Set("node_id", "local:" + node->uuid().AsLowercaseString());
      move.Set("title", BoundedUtf8(base::UTF16ToUTF8(node->GetTitle())));
      move.Set("category", BoundedUtf8(base::UTF16ToUTF8(category)));
      preview.Append(std::move(move));
    }
    bookmark_plans_[plan.plan_id] = plan;
    AgentToolResult result =
        SuccessResult(call.action_id, "bookmark plan created without changes");
    result.value.Set("plan_id", plan.plan_id);
    result.value.Set("snapshot_hash", plan.snapshot_hash);
    result.value.Set("moves", std::move(preview));
    result.value.Set("move_count", static_cast<int>(plan.moves.size()));
    result.value.Set("account_bookmarks", "read_only");
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "bookmark.apply") {
    const std::string* plan_id = call.arguments.FindString("plan_id");
    const std::string* snapshot_hash =
        call.arguments.FindString("snapshot_hash");
    auto plan_it =
        plan_id ? bookmark_plans_.find(*plan_id) : bookmark_plans_.end();
    if (!plan_id || !snapshot_hash || plan_it == bookmark_plans_.end() ||
        plan_it->second.task_id != task->id() ||
        plan_it->second.snapshot_hash != *snapshot_hash ||
        BookmarkSnapshot(model) != *snapshot_hash) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "bookmark tree changed after preview"));
      return;
    }

    std::vector<std::pair<const bookmarks::BookmarkNode*, std::u16string>>
        moves;
    for (const BookmarkMove& move : plan_it->second.moves) {
      const bookmarks::BookmarkNode* node =
          GetLocalNodeByUuid(model, move.node_uuid);
      if (!node || !node->is_url()) {
        std::move(callback).Run(
            ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                        "bookmark disappeared before apply"));
        return;
      }
      moves.emplace_back(node, move.category);
    }
    if (moves.empty()) {
      bookmark_plans_.erase(plan_it);
      AgentToolResult result =
          SuccessResult(call.action_id, "bookmark plan had no changes");
      result.value.Set("moved", 0);
      result.value.Set("snapshot_hash", BookmarkSnapshot(model));
      std::move(callback).Run(std::move(result));
      return;
    }

    BookmarkUndoService* undo_service =
        BookmarkUndoServiceFactory::GetForProfile(profile_);
    UndoManager* undo_manager =
        undo_service ? undo_service->undo_manager() : nullptr;
    if (!undo_manager || !model->other_node()) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kToolUnavailable,
                      "bookmark undo service is unavailable"));
      return;
    }
    const std::string before_hash = BookmarkSnapshot(model);
    {
      bookmarks::ScopedGroupBookmarkActions group(model);
      const bookmarks::BookmarkNode* aegis_folder =
          FindChildFolder(model->other_node(), u"Aegis 分类");
      if (!aegis_folder) {
        aegis_folder = model->AddFolder(model->other_node(),
                                        model->other_node()->children().size(),
                                        u"Aegis 分类");
      }
      std::map<std::u16string, const bookmarks::BookmarkNode*> categories;
      for (const auto& [node, category] : moves) {
        auto [it, inserted] = categories.try_emplace(category, nullptr);
        if (!it->second) {
          it->second = FindChildFolder(aegis_folder, category);
          if (!it->second) {
            it->second = model->AddFolder(
                aegis_folder, aegis_folder->children().size(), category);
          }
        }
        model->Move(node, it->second, it->second->children().size());
      }
    }
    const std::string after_hash = BookmarkSnapshot(model);
    if (after_hash == before_hash || undo_manager->undo_count() == 0u) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kVerificationFailed,
                      "bookmark apply produced no verifiable transaction"));
      return;
    }
    BookmarkUndoReceipt receipt{
        .task_id = task->id(),
        .token = base::Uuid::GenerateRandomV4().AsLowercaseString(),
        .before_hash = before_hash,
        .after_hash = after_hash,
        .undo_count = undo_manager->undo_count()};
    const std::string undo_token = receipt.token;
    bookmark_undo_receipts_[undo_token] = std::move(receipt);
    ObserveBookmarkUndoManager(undo_manager);
    bookmark_plans_.erase(plan_it);

    AgentToolResult result =
        SuccessResult(call.action_id, "bookmark plan applied and verified");
    result.value.Set("moved", static_cast<int>(moves.size()));
    result.value.Set("snapshot_hash", after_hash);
    result.value.Set("undo_token", undo_token);
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "bookmark.undo") {
    const std::string* token = call.arguments.FindString("undo_token");
    auto receipt_it = token ? bookmark_undo_receipts_.find(*token)
                            : bookmark_undo_receipts_.end();
    BookmarkUndoService* undo_service =
        BookmarkUndoServiceFactory::GetForProfile(profile_);
    UndoManager* undo_manager =
        undo_service ? undo_service->undo_manager() : nullptr;
    if (!token || receipt_it == bookmark_undo_receipts_.end() ||
        receipt_it->second.task_id != task->id() || !undo_manager ||
        bookmark_undo_manager_ != undo_manager ||
        BookmarkSnapshot(model) != receipt_it->second.after_hash ||
        undo_manager->undo_count() != receipt_it->second.undo_count) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "undo token is stale or another bookmark edit occurred"));
      return;
    }
    const std::string expected_hash = receipt_it->second.before_hash;
    bookmark_undo_receipts_.erase(receipt_it);
    if (bookmark_undo_receipts_.empty()) {
      StopObservingBookmarkUndoManager();
    }
    undo_manager->Undo();
    if (BookmarkSnapshot(model) != expected_hash) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kVerificationFailed,
                      "bookmark undo completed but verification failed"));
      return;
    }
    AgentToolResult result =
        SuccessResult(call.action_id, "bookmark transaction undone");
    result.value.Set("snapshot_hash", expected_hash);
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "bookmark.check_urls") {
    const base::ListValue* node_ids = call.arguments.FindList("node_ids");
    if (!node_ids || node_ids->empty() ||
        node_ids->size() > kMaxUrlChecksPerCall) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "URL check requires 1 to 100 bookmark node ids"));
      return;
    }
    auto batch = std::make_unique<UrlCheckBatch>();
    batch->task = task;
    batch->task_id = task->id();
    batch->action_id = call.action_id;
    batch->callback = std::move(callback);
    base::flat_set<std::string> unique_ids;
    for (const base::Value& value : *node_ids) {
      const std::string& node_id = value.GetString();
      const bookmarks::BookmarkNode* node =
          GetBookmarkNodeByExternalId(model, node_id);
      if (!node || !node->is_url() ||
          !IsAegisBookmarkUrlCheckTargetAllowed(task->scope(), node->url(),
                                                node->url()) ||
          !unique_ids.insert(node_id).second) {
        std::move(batch->callback)
            .Run(ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                             "bookmark node is invalid, duplicated, or not "
                             "HTTP"));
        return;
      }
      // A selected bookmark node is the network capability for this tool.
      // It is intentionally independent of page-origin scope so a user can
      // check a heterogeneous bookmark tree. Redirects remain separately
      // constrained below, and requests never carry credentials.
      batch->entries.push_back(
          UrlCheckBatch::Entry{.node_id = node_id, .url = node->url()});
    }
    batch->results.resize(batch->entries.size());
    const std::string batch_key = task->id() + ":" + call.action_id;
    if (url_check_batches_.contains(batch_key)) {
      std::move(batch->callback)
          .Run(ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                           "URL check action is already running"));
      return;
    }
    url_check_batches_[batch_key] = std::move(batch);
    PumpUrlCheckRequests(batch_key);
    return;
  }

  std::move(callback).Run(ErrorResult(call.action_id,
                                      AgentErrorCode::kToolUnavailable,
                                      "bookmark tool is not implemented"));
}

void AegisBrowserTools::ExecuteDownloadTool(AgentTask* task,
                                            const AgentToolCall& call,
                                            ToolResultCallback callback) {
  if (call.tool_name == "download.find_official") {
    const std::string* product = call.arguments.FindString("product");
    const std::string* platform = call.arguments.FindString("platform");
    const std::string* architecture = call.arguments.FindString("architecture");
    const std::string* candidate_value =
        call.arguments.FindString("candidate_url");
    const GURL candidate(candidate_value ? *candidate_value : std::string());
    if (!product || !platform || !architecture || !candidate_value ||
        !candidate.is_valid() || !candidate.SchemeIsHTTPOrHTTPS() ||
        !task->scope().AllowsOrigin(candidate) ||
        !task->scope().AllowsOrigin(call.committed_url)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "download candidate is outside the approved scope"));
      return;
    }
    const std::string source_domain =
        net::registry_controlled_domains::GetDomainAndRegistry(
            call.committed_url,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
    const std::string candidate_domain =
        net::registry_controlled_domains::GetDomainAndRegistry(
            candidate,
            net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
    const bool same_site =
        !source_domain.empty() && source_domain == candidate_domain;
    const std::string candidate_text =
        std::string(candidate.host()) + " " + std::string(candidate.path());
    const bool product_match = CandidateMentions(candidate_text, *product);
    const bool platform_match = CandidateMentions(candidate_text, *platform);
    const bool architecture_match =
        CandidateMentions(candidate_text, *architecture);

    AgentToolResult result = SuccessResult(
        call.action_id, "official-source evidence prepared for user review");
    result.value.Set("candidate_url", SafeUrlForModel(candidate));
    result.value.Set("source_url", SafeUrlForModel(call.committed_url));
    result.value.Set("https", candidate.SchemeIs("https"));
    result.value.Set("same_registrable_domain", same_site);
    result.value.Set("product_match", product_match);
    result.value.Set("platform_match", platform_match);
    result.value.Set("architecture_match", architecture_match);
    result.value.Set("official_likelihood",
                     candidate.SchemeIs("https") && same_site && product_match
                         ? "high"
                         : "requires_review");
    result.value.Set("publisher_identity_verified", false);
    result.value.Set("requires_user_review", true);
    std::move(callback).Run(std::move(result));
    return;
  }

  content::DownloadManager* manager = profile_->GetDownloadManager();
  if (!manager) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kToolUnavailable,
                                        "download manager is unavailable"));
    return;
  }

  if (call.tool_name == "download.start") {
    const std::string* url_value = call.arguments.FindString("url");
    const std::optional<int> tab_id = call.arguments.FindInt("tab_id");
    const std::string* expected = call.arguments.FindString("expected_sha256");
    const GURL url(url_value ? *url_value : std::string());
    std::optional<LocatedTab> located = tab_id && task->AllowsTab(*tab_id)
                                            ? FindTab(profile_, *tab_id)
                                            : std::nullopt;
    if (!url_value || !located || !task->scope().AllowsOrigin(url) ||
        !url.SchemeIsHTTPOrHTTPS() ||
        located->tab->GetURL() != call.committed_url || !call.document ||
        call.document->tab_id != *tab_id) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                      "download source tab or URL is outside task scope"));
      return;
    }
    if (expected && !IsSha256Hex(*expected)) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kInvalidRequest,
                      "expected SHA-256 must be exactly 64 hex characters"));
      return;
    }
    if (!task->ConsumeNetworkRequest()) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kBudgetExhausted,
                      "network budget exhausted before download"));
      return;
    }
    content::WebContents* contents = located->tab->GetContents();
    content::RenderFrameHost* frame =
        contents ? contents->GetPrimaryMainFrame() : nullptr;
    if (!frame) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "download source frame is unavailable"));
      return;
    }
    if (frame->GetGlobalFrameToken().frame_token.ToString() !=
        call.document->frame_token) {
      std::move(callback).Run(
          ErrorResult(call.action_id, AgentErrorCode::kStaleDocument,
                      "download source document changed before approval"));
      return;
    }
    static constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
        net::DefineNetworkTrafficAnnotation("aegis_agent_download", R"(
          semantics {
            sender: "Aegis Browser Agent download"
            description:
              "Starts a browser download from an exact user-approved action."
            trigger:
              "The user approves the exact source tab and download URL."
            data: "The approved URL without Agent-supplied credentials."
            destination: WEBSITE
            internal {
              contacts { email: "chromium-dev@chromium.org" }
            }
            user_data { type: NONE }
            last_reviewed: "2026-08-28"
          }
          policy {
            cookies_allowed: NO
            setting:
              "Disabled unless Aegis Agent is enabled and the exact action "
              "is approved by the user."
            policy_exception_justification:
              "The profile setting and exact action approval are implemented."
          })");
    auto parameters =
        frame->CreateDownloadUrlParameters(url, kTrafficAnnotation);
    parameters->set_content_initiated(true);
    parameters->set_credentials_mode(network::mojom::CredentialsMode::kOmit);
    parameters->set_cross_origin_redirects(
        network::mojom::RedirectMode::kError);
    parameters->set_do_not_prompt_for_login(true);
    parameters->set_require_safety_checks(true);
    parameters->set_download_source(download::DownloadSource::WEB_CONTENTS_API);
    parameters->set_has_user_gesture(false);
    const std::string pending_token =
        base::Uuid::GenerateRandomV4().AsLowercaseString();
    pending_download_tasks_[pending_token] = task->id();
    parameters->set_callback(base::BindOnce(
        &AegisBrowserTools::OnDownloadStarted, weak_ptr_factory_.GetWeakPtr(),
        pending_token, task->id(), task->scope(), call.action_id,
        expected ? base::ToLowerASCII(*expected) : std::string(),
        std::move(callback)));
    manager->DownloadUrl(std::move(parameters));
    return;
  }

  auto owned = owned_downloads_.find(task->id());
  if (call.tool_name == "download.list") {
    AgentToolResult result =
        SuccessResult(call.action_id, "task-owned downloads listed");
    base::ListValue downloads;
    if (owned != owned_downloads_.end()) {
      for (const std::string& guid : owned->second) {
        download::DownloadItem* item = manager->GetDownloadByGuid(guid);
        if (!item || !task->scope().AllowsOrigin(item->GetURL())) {
          continue;
        }
        base::DictValue value;
        value.Set("download_id", item->GetGuid());
        value.Set("state", DownloadStateString(item->GetState()));
        value.Set("paused", item->IsPaused());
        value.Set("dangerous", item->IsDangerous());
        value.Set("received_bytes",
                  base::NumberToString(item->GetReceivedBytes()));
        value.Set("total_bytes", base::NumberToString(item->GetTotalBytes()));
        value.Set(
            "file_name",
            BoundedUtf8(
                item->GetFileNameToReportUser().BaseName().AsUTF8Unsafe()));
        value.Set("final_url", SafeUrlForModel(item->GetURL()));
        downloads.Append(std::move(value));
      }
    }
    result.value.Set("downloads", std::move(downloads));
    std::move(callback).Run(std::move(result));
    return;
  }

  const std::string* download_id = call.arguments.FindString("download_id");
  download::DownloadItem* item = download_id &&
                                         owned != owned_downloads_.end() &&
                                         owned->second.contains(*download_id)
                                     ? manager->GetDownloadByGuid(*download_id)
                                     : nullptr;
  if (!item) {
    std::move(callback).Run(ErrorResult(call.action_id,
                                        AgentErrorCode::kScopeViolation,
                                        "download is not owned by this task"));
    return;
  }
  if ((call.tool_name == "download.verify" ||
       call.tool_name == "download.open") &&
      !task->scope().AllowsOrigin(item->GetURL())) {
    std::move(callback).Run(
        ErrorResult(call.action_id, AgentErrorCode::kScopeViolation,
                    "download final URL is outside task scope"));
    return;
  }

  if (call.tool_name == "download.pause") {
    if (item->GetState() != download::DownloadItem::IN_PROGRESS ||
        item->IsPaused()) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kInvalidRequest,
                                          "download is not actively running"));
      return;
    }
    item->Pause();
    AgentToolResult result = SuccessResult(call.action_id, "download paused");
    result.value.Set("download_id", item->GetGuid());
    result.value.Set("paused", item->IsPaused());
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "download.cancel") {
    if (item->GetState() != download::DownloadItem::IN_PROGRESS &&
        item->GetState() != download::DownloadItem::INTERRUPTED) {
      std::move(callback).Run(ErrorResult(
          call.action_id, AgentErrorCode::kInvalidRequest,
          "only an active or interrupted download can be cancelled"));
      return;
    }
    item->Cancel(/*user_cancel=*/true);
    AgentToolResult result =
        SuccessResult(call.action_id, "download cancelled");
    result.value.Set("download_id", item->GetGuid());
    result.value.Set("state", DownloadStateString(item->GetState()));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "download.resume") {
    if (!item->CanResume()) {
      std::move(callback).Run(ErrorResult(call.action_id,
                                          AgentErrorCode::kInvalidRequest,
                                          "download cannot be resumed"));
      return;
    }
    item->Resume(/*user_resume=*/false);
    AgentToolResult result = SuccessResult(call.action_id, "download resumed");
    result.value.Set("download_id", item->GetGuid());
    result.value.Set("paused", item->IsPaused());
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "download.open") {
    const std::string actual_hash = item->GetHash().size() == 32u
                                        ? base::HexEncode(item->GetHash())
                                        : std::string();
    const auto expected_it = expected_download_hashes_.find(item->GetGuid());
    const std::string expected_hash =
        expected_it == expected_download_hashes_.end() ? std::string()
                                                       : expected_it->second;
    const bool hash_matches =
        !expected_hash.empty() && !actual_hash.empty() &&
        base::EqualsCaseInsensitiveASCII(expected_hash, actual_hash);
    const bool verified =
        item->GetState() == download::DownloadItem::COMPLETE &&
        !item->IsDangerous() && !item->GetFileExternallyRemoved() &&
        item->CanOpenDownload() && hash_matches;
    if (!verified) {
      std::move(callback).Run(ErrorResult(
          call.action_id, AgentErrorCode::kVerificationFailed,
          "download must be complete, safe, present, and verified"));
      return;
    }
    item->OpenDownload();
    AgentToolResult result =
        SuccessResult(call.action_id, "verified download opened");
    result.value.Set("download_id", item->GetGuid());
    result.value.Set("opened", true);
    result.value.Set("state", DownloadStateString(item->GetState()));
    std::move(callback).Run(std::move(result));
    return;
  }

  if (call.tool_name == "download.verify") {
    const bool complete = item->GetState() == download::DownloadItem::COMPLETE;
    const bool safe = !item->IsDangerous();
    const std::string actual_hash = item->GetHash().size() == 32u
                                        ? base::HexEncode(item->GetHash())
                                        : std::string();
    const auto expected_it = expected_download_hashes_.find(item->GetGuid());
    const std::string expected_hash =
        expected_it == expected_download_hashes_.end() ? std::string()
                                                       : expected_it->second;
    const bool hash_matches =
        !expected_hash.empty() && !actual_hash.empty() &&
        base::EqualsCaseInsensitiveASCII(expected_hash, actual_hash);
    const bool safe_and_complete =
        complete && safe && !item->GetFileExternallyRemoved();
    const bool verified = safe_and_complete && hash_matches;
    AgentToolResult result = SuccessResult(
        call.action_id,
        verified ? "download state verified" : "download is not yet verified");
    result.value.Set("download_id", item->GetGuid());
    result.value.Set("state", DownloadStateString(item->GetState()));
    result.value.Set("paused", item->IsPaused());
    result.value.Set("dangerous", item->IsDangerous());
    result.value.Set("danger_type", static_cast<int>(item->GetDangerType()));
    result.value.Set("received_bytes",
                     base::NumberToString(item->GetReceivedBytes()));
    result.value.Set("total_bytes",
                     base::NumberToString(item->GetTotalBytes()));
    result.value.Set(
        "file_name",
        BoundedUtf8(item->GetFileNameToReportUser().BaseName().AsUTF8Unsafe()));
    result.value.Set("final_url", SafeUrlForModel(item->GetURL()));
    result.value.Set("verified", verified);
    result.value.Set("safe_and_complete", safe_and_complete);
    result.value.Set("integrity",
                     expected_hash.empty()
                         ? "not_provided"
                         : (hash_matches ? "match" : "not_matched"));
    if (!actual_hash.empty()) {
      result.value.Set("sha256", base::ToLowerASCII(actual_hash));
    }
    std::move(callback).Run(std::move(result));
    return;
  }

  std::move(callback).Run(ErrorResult(call.action_id,
                                      AgentErrorCode::kToolUnavailable,
                                      "download tool is not implemented"));
}

void AegisBrowserTools::OnDownloadStarted(
    std::string pending_token,
    const std::string& task_id,
    AgentTaskScope scope,
    std::string action_id,
    std::string expected_sha256,
    ToolResultCallback callback,
    download::DownloadItem* item,
    download::DownloadInterruptReason reason) {
  auto pending = pending_download_tasks_.find(pending_token);
  if (pending == pending_download_tasks_.end() || pending->second != task_id) {
    if (item) {
      item->Cancel(/*user_cancel=*/true);
    }
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kCancelled,
                    "download start was cancelled with its task"));
    return;
  }
  pending_download_tasks_.erase(pending);
  if (!item || reason != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kVerificationFailed,
                    "download did not start: " +
                        download::DownloadInterruptReasonToString(reason)));
    return;
  }
  if (!scope.AllowsOrigin(item->GetURL())) {
    item->Cancel(/*user_cancel=*/true);
    std::move(callback).Run(
        ErrorResult(std::move(action_id), AgentErrorCode::kScopeViolation,
                    "download redirected outside the approved origin"));
    return;
  }
  owned_downloads_[task_id].insert(item->GetGuid());
  if (!expected_sha256.empty()) {
    expected_download_hashes_[item->GetGuid()] = std::move(expected_sha256);
  }
  AgentToolResult result =
      SuccessResult(std::move(action_id), "browser download started");
  result.value.Set("download_id", item->GetGuid());
  result.value.Set("state", DownloadStateString(item->GetState()));
  result.value.Set("dangerous", item->IsDangerous());
  result.value.Set(
      "file_name",
      BoundedUtf8(item->GetFileNameToReportUser().BaseName().AsUTF8Unsafe()));
  result.value.Set("source_url", SafeUrlForModel(item->GetOriginalUrl()));
  result.value.Set("safety_checks_required", true);
  std::move(callback).Run(std::move(result));
}

void AegisBrowserTools::PumpUrlCheckRequests(const std::string& batch_key) {
  auto it = url_check_batches_.find(batch_key);
  if (it == url_check_batches_.end()) {
    return;
  }
  UrlCheckBatch& batch = *it->second;
  if (!batch.task || IsTerminalState(batch.task->state())) {
    ToolResultCallback callback = std::move(batch.callback);
    const std::string action_id = batch.action_id;
    url_check_batches_.erase(it);
    std::move(callback).Run(
        ErrorResult(action_id, AgentErrorCode::kCancelled,
                    "URL check stopped because the task is no longer active"));
    return;
  }
  if (batch.completed == batch.entries.size()) {
    AgentToolResult result = SuccessResult(
        batch.action_id, "bookmark URLs checked without credentials");
    base::ListValue values;
    for (std::optional<base::DictValue>& value : batch.results) {
      if (value) {
        values.Append(std::move(*value));
      }
    }
    result.value.Set("results", std::move(values));
    ToolResultCallback callback = std::move(batch.callback);
    url_check_batches_.erase(it);
    std::move(callback).Run(std::move(result));
    return;
  }

  batch.retry_timer.Stop();
  while (batch.loaders.size() < kMaxConcurrentUrlChecks) {
    const base::TimeTicks now = base::TimeTicks::Now();
    std::optional<size_t> candidate;
    std::optional<base::TimeTicks> earliest_retry;
    for (size_t index = 0; index < batch.entries.size(); ++index) {
      const UrlCheckBatch::Entry& entry = batch.entries[index];
      if (entry.active || entry.completed) {
        continue;
      }
      const std::string origin = url::Origin::Create(entry.url).Serialize();
      if (batch.active_origins.contains(origin)) {
        continue;
      }
      if (!entry.not_before.is_null() && entry.not_before > now) {
        if (!earliest_retry || entry.not_before < *earliest_retry) {
          earliest_retry = entry.not_before;
        }
        continue;
      }
      candidate = index;
      break;
    }
    if (!candidate) {
      if (earliest_retry) {
        batch.retry_timer.Start(
            FROM_HERE, std::max(base::Milliseconds(1), *earliest_retry - now),
            base::BindOnce(&AegisBrowserTools::PumpUrlCheckRequests,
                           weak_ptr_factory_.GetWeakPtr(), batch_key));
      }
      return;
    }
    StartUrlCheckRequest(batch_key, *candidate);
    if (!url_check_batches_.contains(batch_key)) {
      return;
    }
  }
}

void AegisBrowserTools::StartUrlCheckRequest(const std::string& batch_key,
                                             size_t index) {
  auto it = url_check_batches_.find(batch_key);
  if (it == url_check_batches_.end() || index >= it->second->entries.size()) {
    return;
  }
  UrlCheckBatch& batch = *it->second;
  UrlCheckBatch::Entry& entry = batch.entries[index];
  if (!batch.task || IsTerminalState(batch.task->state()) || entry.active ||
      entry.completed || !batch.task->ConsumeNetworkRequest()) {
    ToolResultCallback callback = std::move(batch.callback);
    const std::string action_id = batch.action_id;
    url_check_batches_.erase(it);
    std::move(callback).Run(
        ErrorResult(action_id, AgentErrorCode::kBudgetExhausted,
                    "network budget exhausted during URL check"));
    return;
  }

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = entry.url;
  request->method = entry.use_get ? "GET" : "HEAD";
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_DISABLE_CACHE | net::LOAD_BYPASS_CACHE;
  if (entry.use_get) {
    request->headers.SetHeader(net::HttpRequestHeaders::kRange, "bytes=0-0");
  }
  static constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
      net::DefineNetworkTrafficAnnotation("aegis_bookmark_url_check", R"(
        semantics {
          sender: "Aegis Browser Agent bookmark URL checker"
          description:
            "Checks whether a user-selected bookmark URL still responds."
          trigger:
            "The user approves an Aegis task that checks selected bookmarks."
          data: "The selected bookmark URL. No cookies or credentials."
          destination: WEBSITE
          internal {
            contacts { email: "chromium-dev@chromium.org" }
          }
          user_data { type: NONE }
          last_reviewed: "2026-08-28"
        }
        policy {
          cookies_allowed: NO
          setting:
            "Disabled unless the Aegis Agent feature and profile preference "
            "are enabled and the user approves the task."
          policy_exception_justification:
            "The profile setting is implemented and disabled by default."
        })");
  entry.active = true;
  entry.redirects.clear();
  batch.active_origins.insert(url::Origin::Create(entry.url).Serialize());
  std::unique_ptr<network::SimpleURLLoader> loader =
      network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
  loader->SetURLLoaderFactoryOptions(
      network::mojom::kURLLoadOptionBlockLocalRequest);
  loader->SetTimeoutDuration(base::Seconds(10));
  loader->SetRetryOptions(0, network::SimpleURLLoader::RETRY_NEVER);
  loader->SetAllowHttpErrorResults(true);
  loader->SetOnRedirectCallback(
      base::BindRepeating(&AegisBrowserTools::OnUrlCheckRedirect,
                          weak_ptr_factory_.GetWeakPtr(), batch_key, index));
  network::SimpleURLLoader* loader_ptr = loader.get();
  batch.loaders[index] = std::move(loader);
  loader_ptr->DownloadHeadersOnly(
      profile_->GetDefaultStoragePartition()
          ->GetURLLoaderFactoryForBrowserProcess()
          .get(),
      base::BindOnce(&AegisBrowserTools::OnUrlCheckComplete,
                     weak_ptr_factory_.GetWeakPtr(), batch_key, index));
}

void AegisBrowserTools::OnUrlCheckRedirect(
    const std::string& batch_key,
    size_t index,
    const GURL& url_before_redirect,
    const net::RedirectInfo& redirect_info,
    const network::mojom::URLResponseHead& response_head,
    std::vector<std::string>* removed_headers) {
  auto it = url_check_batches_.find(batch_key);
  if (it == url_check_batches_.end() || index >= it->second->entries.size()) {
    return;
  }
  UrlCheckBatch& batch = *it->second;
  UrlCheckBatch::Entry& entry = batch.entries[index];
  const GURL& target = redirect_info.new_url;
  const std::string target_origin = url::Origin::Create(target).Serialize();
  bool belongs_to_entry =
      url::Origin::Create(entry.url).Serialize() == target_origin;
  for (const GURL& redirect : entry.redirects) {
    belongs_to_entry =
        belongs_to_entry ||
        url::Origin::Create(redirect).Serialize() == target_origin;
  }

  if (IsAegisBookmarkUrlCheckTargetAllowed(batch.task->scope(), entry.url,
                                           target) &&
      entry.redirects.size() < kMaxUrlCheckRedirects &&
      (!batch.active_origins.contains(target_origin) || belongs_to_entry)) {
    entry.redirects.push_back(target);
    batch.active_origins.insert(target_origin);
    return;
  }

  base::DictValue checked;
  checked.Set("node_id", entry.node_id);
  checked.Set("url", SafeUrlForModel(entry.url));
  checked.Set("classification", IsAegisBookmarkUrlCheckTargetAllowed(
                                    batch.task->scope(), entry.url, target)
                                    ? "indeterminate"
                                    : "scope_blocked");
  checked.Set("http_status", response_head.headers
                                 ? response_head.headers->response_code()
                                 : 0);
  checked.Set("redirect_from", SafeUrlForModel(url_before_redirect));
  checked.Set("redirect_blocked", true);
  batch.results[index] = std::move(checked);
  entry.active = false;
  entry.completed = true;
  ++batch.completed;
  batch.active_origins.erase(url::Origin::Create(entry.url).Serialize());
  for (const GURL& redirect : entry.redirects) {
    batch.active_origins.erase(url::Origin::Create(redirect).Serialize());
  }
  batch.loaders.erase(index);
  PumpUrlCheckRequests(batch_key);
}

void AegisBrowserTools::OnUrlCheckComplete(
    const std::string& batch_key,
    size_t index,
    scoped_refptr<net::HttpResponseHeaders> response_headers) {
  auto it = url_check_batches_.find(batch_key);
  if (it == url_check_batches_.end() || index >= it->second->entries.size()) {
    return;
  }
  UrlCheckBatch& batch = *it->second;
  UrlCheckBatch::Entry& entry = batch.entries[index];
  auto loader_it = batch.loaders.find(index);
  if (loader_it == batch.loaders.end()) {
    return;
  }
  const int response_code =
      response_headers ? response_headers->response_code() : 0;
  if (!entry.use_get && (response_code == 405 || response_code == 501)) {
    entry.active = false;
    entry.use_get = true;
    batch.active_origins.erase(url::Origin::Create(entry.url).Serialize());
    for (const GURL& redirect : entry.redirects) {
      batch.active_origins.erase(url::Origin::Create(redirect).Serialize());
    }
    batch.loaders.erase(loader_it);
    PumpUrlCheckRequests(batch_key);
    return;
  }

  const int net_error = loader_it->second->NetError();
  const GURL final_url = loader_it->second->GetFinalURL();
  const bool redirected = final_url.is_valid() && final_url != entry.url;
  base::DictValue checked;
  checked.Set("node_id", entry.node_id);
  checked.Set("url", SafeUrlForModel(entry.url));
  const bool final_allowed = IsAegisBookmarkUrlCheckTargetAllowed(
      batch.task->scope(), entry.url, final_url);
  checked.Set("classification",
              final_allowed
                  ? UrlCheckClassification(net_error, response_code, redirected)
                  : "scope_blocked");
  checked.Set("http_status", response_code);
  if (redirected && final_allowed) {
    checked.Set("final_url", SafeUrlForModel(final_url));
  }
  base::ListValue redirect_chain;
  for (const GURL& redirect : entry.redirects) {
    redirect_chain.Append(SafeUrlForModel(redirect));
  }
  checked.Set("redirect_chain", std::move(redirect_chain));
  batch.results[index] = std::move(checked);
  entry.active = false;
  entry.completed = true;
  ++batch.completed;

  const std::string origin = url::Origin::Create(entry.url).Serialize();
  batch.active_origins.erase(origin);
  for (const GURL& redirect : entry.redirects) {
    batch.active_origins.erase(url::Origin::Create(redirect).Serialize());
  }
  batch.loaders.erase(loader_it);

  if (response_code == 429) {
    int retry_after_seconds = 5;
    if (response_headers) {
      const std::optional<std::string> retry_after =
          response_headers->GetNormalizedHeader("retry-after");
      int parsed = 0;
      if (retry_after && base::StringToInt(*retry_after, &parsed)) {
        retry_after_seconds = std::clamp(parsed, 1, 60);
      }
    }
    const base::TimeTicks not_before =
        base::TimeTicks::Now() + base::Seconds(retry_after_seconds);
    for (UrlCheckBatch::Entry& pending : batch.entries) {
      if (!pending.active && !pending.completed &&
          url::Origin::Create(pending.url).Serialize() == origin) {
        pending.not_before = std::max(pending.not_before, not_before);
      }
    }
  }
  PumpUrlCheckRequests(batch_key);
}

}  // namespace aegis::agent
