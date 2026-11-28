// 原生资料访问。云端数据必须先通过整棵树的校验，再在同一 UI
// 任务内替换专用目录。
#include "chrome/browser/ui/webui/aegis/link_profile_data.h"

#include "base/location.h"
#include "base/strings/utf_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/bookmarks/bookmark_model_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/link_account.h"
#include "chrome/common/pref_names.h"
#include "components/bookmarks/browser/bookmark_model.h"
#include "components/bookmarks/common/bookmark_metrics.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"

namespace aegis::link {
namespace {
using bookmarks::BookmarkModel;
using bookmarks::BookmarkNode;

bool ValidTree(const base::ListValue& rows, unsigned depth, int& left) {
  if (depth > 40)
    return false;
  for (const auto& row : rows) {
    const auto* item = row.GetIfDict();
    if (!item || --left < 0)
      return false;
    const auto* title = item->FindString("title");
    const auto* url = item->FindString("url");
    const auto* children = item->FindList("children");
    if (!title || title->size() > 32768 || (!!url == !!children))
      return false;
    if (children) {
      if (!ValidTree(*children, depth + 1, left))
        return false;
    } else {
      const GURL address(*url);
      if (url->size() > 32768 || !address.is_valid() ||
          !address.SchemeIsHTTPOrHTTPS() || address.has_username() ||
          address.has_password())
        return false;
    }
  }
  return true;
}

bool ReadTree(const BookmarkNode* folder,
              base::ListValue& rows,
              unsigned depth,
              int& left) {
  if (depth > 40)
    return false;
  for (const auto& child : folder->children()) {
    if (--left < 0)
      return false;
    base::DictValue row;
    row.Set("title", base::UTF16ToUTF8(child->GetTitle()));
    if (child->is_folder()) {
      base::ListValue nested;
      if (!ReadTree(child.get(), nested, depth + 1, left))
        return false;
      row.Set("children", std::move(nested));
    } else {
      row.Set("url", child->url().spec());
    }
    rows.Append(std::move(row));
  }
  return true;
}

void Fill(BookmarkModel* model,
          const BookmarkNode* folder,
          const base::ListValue& rows) {
  for (const auto& row : rows) {
    const auto& item = row.GetDict();
    const auto title = base::UTF8ToUTF16(*item.FindString("title"));
    const size_t index = folder->children().size();
    if (const auto* nested = item.FindList("children"))
      Fill(model, model->AddFolder(folder, index, title), *nested);
    else
      model->AddURL(folder, index, title, GURL(*item.FindString("url")));
  }
}
}  // namespace

base::expected<base::Value, const char*> ProfileData(
    Profile* profile,
    std::string_view account,
    std::string_view email,
    std::string_view collection,
    const base::DictValue& input) {
  PrefService* prefs = profile->GetPrefs();
  const auto* after = input.Find("value");
  const auto* before = input.Find("before");
  if (collection == "preferences") {
    base::DictValue current;
    current.Set("defaultSize",
                prefs->GetInteger(prefs::kWebKitDefaultFontSize));
    current.Set("minimumSize",
                prefs->GetInteger(prefs::kWebKitMinimumFontSize));
    if (!after)
      return base::Value(std::move(current));
    if (!before || !before->is_dict() || current != before->GetDict())
      return base::unexpected("conflict");
    if (!after->is_dict())
      return base::unexpected("invalid");
    auto normal = after->GetDict().FindInt("defaultSize");
    auto minimum = after->GetDict().FindInt("minimumSize");
    if (!normal || *normal < 1 || *normal > 100 || !minimum || *minimum < 0 ||
        *minimum > 100)
      return base::unexpected("invalid");
    if (!prefs->FindPreference(prefs::kWebKitDefaultFontSize)
             ->IsUserModifiable() ||
        !prefs->FindPreference(prefs::kWebKitMinimumFontSize)
             ->IsUserModifiable())
      return base::unexpected("settings");
    prefs->SetInteger(prefs::kWebKitDefaultFontSize, *normal);
    prefs->SetInteger(prefs::kWebKitMinimumFontSize, *minimum);
    return base::Value(true);
  }
  if (collection != "bookmarks")
    return base::unexpected("invalid");
  auto* model = BookmarkModelFactory::GetForBrowserContext(profile);
  if (!model || !model->loaded())
    return base::unexpected("folder");
  auto* parent = model->bookmark_bar_node();
  const BookmarkNode* folder = nullptr;
  const auto* stored = prefs->GetDict(kFolders).FindString(account);
  if (stored)
    folder = model->GetNodeByUuid(
        base::Uuid::ParseCaseInsensitive(*stored),
        BookmarkModel::NodeTypeForUuidLookup::kLocalOrSyncableNodes);
  const auto name = u"Aegis Link · " + base::UTF8ToUTF16(email);
  if (!folder || !folder->is_folder() || model->is_permanent_node(folder)) {
    folder = model->AddFolder(parent, parent->children().size(), name);
    ScopedDictPrefUpdate(prefs, kFolders)
        ->Set(account, folder->uuid().AsLowercaseString());
  }
  base::ListValue current;
  int left = 10000;
  if (!ReadTree(folder, current, 0, left))
    return base::unexpected("limit");
  left = 10000;
  if (!ValidTree(current, 0, left))
    return base::unexpected("invalid");
  if (!after)
    return base::Value(std::move(current));
  if (!before || !before->is_list() || before->GetList() != current)
    return base::unexpected("conflict");
  left = 10000;
  if (!after->is_list() || !ValidTree(after->GetList(), 0, left))
    return base::unexpected("invalid");
  // 显式选择云端副本时仍留下本地旧目录；自动更新则保持同一目录 UUID。
  if (input.FindBool("backup").value_or(false) && !current.empty())
    Fill(model,
         model->AddFolder(parent, parent->children().size(),
                          name + u" (backup)"),
         current);
  while (!folder->children().empty())
    model->Remove(folder->children().back().get(),
                  bookmarks::metrics::BookmarkEditSource::kOther, FROM_HERE);
  Fill(model, folder, after->GetList());
  return base::Value(true);
}
}  // namespace aegis::link
