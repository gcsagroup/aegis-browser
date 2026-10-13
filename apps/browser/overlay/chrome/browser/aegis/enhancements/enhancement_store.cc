// Copyright 2026 GCSA
#include "chrome/browser/aegis/enhancements/enhancement_store.h"

#include <algorithm>
#include <array>
#include <set>
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/strings/pattern.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/task/thread_pool.h"
#include "base/uuid.h"
#include "chrome/browser/profiles/profile.h"
#include "third_party/re2/src/re2/re2.h"
#include "url/origin.h"

namespace aegis {
namespace {
const char kStoreKey[] = "aegis.website-enhancements";
constexpr size_t kMaxBytes = 8 * 1024 * 1024;
constexpr std::array<std::string_view, 5> kGrants = {
    "GM_addStyle", "GM.getValue", "GM.setValue", "GM.deleteValue",
    "GM_registerMenuCommand"};
bool Flag(const base::DictValue& value, std::string_view key) {
  return value.FindBool(key).value_or(false);
}
struct Pattern {
  std::string scheme, host, port, path;
};
std::optional<Pattern> ParsePattern(const std::string& pattern) {
  static const base::NoDestructor<re2::RE2> expression(
      R"((?i)^(https?|\*)://(\*|\*\.[a-z0-9.-]+|[a-z0-9.-]+|\[[a-f0-9:]+\])(:[0-9]{1,5})?(/[^\s]*)$)");
  Pattern p;
  if (!re2::RE2::FullMatch(pattern, *expression, &p.scheme, &p.host, &p.port,
                           &p.path) ||
      p.host.contains(".."))
    return std::nullopt;
  int port = 0;
  if (!p.port.empty() &&
      (!base::StringToInt(p.port.substr(1), &port) || port < 1 || port > 65535))
    return std::nullopt;
  p.scheme = base::ToLowerASCII(p.scheme);
  p.host = base::ToLowerASCII(p.host);
  return p;
}
bool WebURL(const GURL& url) {
  return url.is_valid() && url.SchemeIsHTTPOrHTTPS() && !url.has_username() &&
         !url.has_password();
}
bool OriginMatches(const base::DictValue& rule, const GURL& url) {
  GURL origin(EnhancementField(rule, "origin"));
  return WebURL(url) && origin.scheme() == url.scheme() &&
         origin.EffectiveIntPort() == url.EffectiveIntPort() &&
         (origin.host() == url.host() ||
          (Flag(rule, "subdomains") &&
           base::EndsWith(url.host(), "." + std::string(origin.host()))));
}
}  // namespace
std::string EnhancementField(const base::DictValue& value,
                             std::string_view key) {
  const auto* s = value.FindString(key);
  return s ? *s : "";
}
EnhancementStore* EnhancementStore::Get(Profile* profile) {
  auto* store = static_cast<EnhancementStore*>(profile->GetUserData(kStoreKey));
  if (!store) {
    auto owned = std::make_unique<EnhancementStore>(
        profile->IsOffTheRecord()
            ? base::FilePath()
            : profile->GetPath().AppendASCII("website-enhancements-v1.json"));
    store = owned.get();
    profile->SetUserData(kStoreKey, std::move(owned));
  }
  return store;
}
EnhancementStore::EnhancementStore(base::FilePath path)
    : path_(std::move(path)) {
  state_ = base::DictValue()
               .Set("schema", 1)
               .Set("revision", 0)
               .Set("sites", base::ListValue())
               .Set("scripts", base::ListValue())
               .Set("values", base::DictValue());
  if (path_.empty())
    return;
  ready_ = false;
  io_ = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  io_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](base::FilePath path) {
            base::DictValue result;
            if (!base::PathExists(path)) {
              result.Set("bytes", "");
              return result;
            }
            std::string bytes;
            if (!base::ReadFileToStringWithMaxSize(path, &bytes, kMaxBytes))
              result.Set("error", "脚本存储读取失败。");
            else
              result.Set("bytes", bytes);
            return result;
          },
          path_),
      base::BindOnce(
          [](base::WeakPtr<EnhancementStore> self, base::DictValue result) {
            if (!self)
              return;
            self->ready_ = true;
            self->disk_bytes_ = EnhancementField(result, "bytes");
            auto state = base::JSONReader::ReadDict(self->disk_bytes_,
                                                    base::JSON_PARSE_RFC);
            if (result.FindString("error") ||
                (!self->disk_bytes_.empty() && (!state || !Validate(*state)))) {
              self->readable_ = false;
              self->error_ = "脚本存储不可读，原文件已保留。";
            } else if (state)
              self->state_ = std::move(*state);
            self->observers_.Notify();
          },
          weak_.GetWeakPtr()));
}
EnhancementStore::~EnhancementStore() = default;
base::CallbackListSubscription EnhancementStore::Observe(
    base::RepeatingClosure callback) {
  return observers_.Add(std::move(callback));
}
const base::DictValue* EnhancementStore::Script(const std::string& id) const {
  for (const auto& script : *state_.FindList("scripts"))
    if (EnhancementField(script.GetDict(), "id") == id)
      return &script.GetDict();
  return nullptr;
}
const base::DictValue* EnhancementStore::Rule(const GURL& url) const {
  const base::DictValue* found = nullptr;
  for (const auto& item : *state_.FindList("sites")) {
    const auto& rule = item.GetDict();
    if (OriginMatches(rule, url) &&
        (!found || EnhancementField(rule, "origin").size() >
                       EnhancementField(*found, "origin").size()))
      found = &rule;
  }
  return found;
}
bool EnhancementStore::Matches(const std::string& pattern, const GURL& url) {
  auto p = ParsePattern(pattern);
  if (!p || !WebURL(url) || (p->scheme != "*" && p->scheme != url.scheme()))
    return false;
  if (p->host != "*" && p->host != url.host() &&
      !(p->host.starts_with("*.") &&
        (url.host() == p->host.substr(2) ||
         base::EndsWith(url.host(), p->host.substr(1)))))
    return false;
  if (!p->port.empty()) {
    int port = 0;
    base::StringToInt(p->port.substr(1), &port);
    if (port != url.EffectiveIntPort())
      return false;
  }
  // 仅星号是通配符，问号是 URL 查询分隔符。
  const std::string address =
      std::string(url.path()) +
      (url.has_query() ? "?" + std::string(url.query()) : "");
  std::string regex = "^";
  auto pieces = base::SplitString(p->path, "*", base::KEEP_WHITESPACE,
                                  base::SPLIT_WANT_ALL);
  for (size_t i = 0; i < pieces.size(); ++i) {
    if (i)
      regex += ".*";
    regex += re2::RE2::QuoteMeta(pieces[i]);
  }
  return re2::RE2::FullMatch(address, regex + "$");
}
bool EnhancementStore::PausedAt(const base::DictValue& script, const GURL& url) {
  const auto* origins = script.FindList("disabledOrigins");
  return origins && origins->contains(url::Origin::Create(url).Serialize());
}
bool EnhancementStore::Applies(const base::DictValue& script,
                               const GURL& url,
                               bool top) {
  const auto* metadata = script.FindDict("metadata");
  if (!metadata ||
      (!top && (!Flag(script, "allFrames") || Flag(*metadata, "noframes"))))
    return false;
  bool included = false;
  for (const auto& p : *metadata->FindList("matches"))
    if (Matches(p.GetString(), url))
      included = true;
  for (const auto& p : *metadata->FindList("excludes"))
    if (Matches(p.GetString(), url))
      return false;
  return included;
}
std::optional<base::DictValue> EnhancementStore::ParseMetadata(
    const std::string& source) {
  if (source.size() > 65536 || !base::IsStringUTF8(source))
    return std::nullopt;
  base::DictValue m = base::DictValue()
                          .Set("name", "")
                          .Set("namespace", "")
                          .Set("version", "1.0")
                          .Set("description", "")
                          .Set("matches", base::ListValue())
                          .Set("excludes", base::ListValue())
                          .Set("grants", base::ListValue())
                          .Set("runAt", "document-end")
                          .Set("noframes", false);
  bool started = false, ended = false;
  for (auto line : base::SplitString(source, "\n", base::TRIM_WHITESPACE,
                                     base::SPLIT_WANT_ALL)) {
    if (!started) {
      if (line.empty())
        continue;
      if (line != "// ==UserScript==")
        return std::nullopt;
      started = true;
      continue;
    }
    if (line == "// ==/UserScript==") {
      ended = true;
      break;
    }
    if (!line.starts_with("//"))
      continue;
    line = base::TrimWhitespaceASCII(line.substr(2), base::TRIM_ALL);
    if (!line.starts_with("@"))
      continue;
    const size_t split = line.find_first_of(" \t");
    const std::string key = line.substr(
        1, split == std::string::npos ? std::string::npos : split - 1);
    const std::string value = split == std::string::npos
                                  ? ""
                                  : std::string(base::TrimWhitespaceASCII(
                                        line.substr(split), base::TRIM_ALL));
    if (key == "match" || key == "exclude") {
      if (!ParsePattern(value))
        return std::nullopt;
      m.FindList(key == "match" ? "matches" : "excludes")->Append(value);
    } else if (key == "grant") {
      if (value != "none") {
        if (std::ranges::find(kGrants, value) == kGrants.end())
          return std::nullopt;
        auto* grants = m.FindList("grants");
        if (!grants->contains(value))
          grants->Append(value);
      }
    } else if (key == "run-at") {
      if (value != "document-start" && value != "document-end" &&
          value != "document-idle")
        return std::nullopt;
      m.Set("runAt", value);
    } else if (key == "noframes")
      m.Set("noframes", true);
    else if (key == "name" || key == "namespace" || key == "version" ||
             key == "description") {
      if (value.size() > (key == "description" ? 4000u : 800u))
        return std::nullopt;
      m.Set(key, value);
    } else
      return std::nullopt;
  }
  if (!ended || EnhancementField(m, "name").empty() ||
      m.FindList("matches")->empty() || m.FindList("matches")->size() > 32 ||
      m.FindList("excludes")->size() > 32)
    return std::nullopt;
  return m;
}
bool EnhancementStore::Validate(const base::DictValue& state) {
  const auto* scripts = state.FindList("scripts");
  const auto* sites = state.FindList("sites");
  const auto* values = state.FindDict("values");
  if (state.FindInt("schema") != 1 || !state.FindInt("revision") || !scripts ||
      scripts->size() > 64 || !sites || sites->size() > 200 || !values)
    return false;
  if (const auto* preview = state.FindDict("markdownSites")) {
    if (preview->size() > 200)
      return false;
    for (auto [origin, value] : *preview) {
      const GURL url(origin);
      if (!value.is_bool() || !WebURL(url) ||
          url::Origin::Create(url).Serialize() != origin)
        return false;
    }
  }
  if (const auto* reading = state.FindDict("readingPreferences")) {
    const int font = reading->FindInt("font").value_or(17);
    const auto theme = EnhancementField(*reading, "theme");
    const auto family = EnhancementField(*reading, "family");
    const int width = reading->FindInt("width").value_or(820);
    const int spacing = reading->FindInt("spacing").value_or(180);
    if (font < 12 || font > 28 || (width != 680 && width != 820 && width != 1100) ||
        (spacing != 150 && spacing != 180 && spacing != 210) ||
        (theme != "system" && theme != "light" && theme != "dark") ||
        (family != "sans" && family != "serif"))
      return false;
  }
  std::set<std::string> ids, origins;
  for (const auto& item : *sites) {
    if (!item.is_dict())
      return false;
    const auto& rule = item.GetDict();
    const std::string raw = EnhancementField(rule, "origin");
    const GURL url(raw);
    if (!WebURL(url) || url::Origin::Create(url).Serialize() != raw ||
        !origins.insert(raw).second)
      return false;
    for (const auto* key : {"subdomains", "menu", "copy", "debug", "disabled"})
      if (!rule.FindBool(key))
        return false;
  }
  for (const auto& item : *scripts) {
    if (!item.is_dict())
      return false;
    const auto& s = item.GetDict();
    const std::string id = EnhancementField(s, "id"),
                      world = EnhancementField(s, "world");
    auto m = ParseMetadata(EnhancementField(s, "source"));
    const auto* history = s.FindList("history");
    if (const auto* disabled = s.FindList("disabledOrigins")) {
      if (disabled->size() > 200)
        return false;
      for (const auto& origin : *disabled) {
        if (!origin.is_string() || !WebURL(GURL(origin.GetString())) ||
            url::Origin::Create(GURL(origin.GetString())).Serialize() !=
                origin.GetString())
          return false;
      }
    } else if (s.contains("disabledOrigins")) {
      return false;
    }
    if (!base::Uuid::ParseCaseInsensitive(id).is_valid() ||
        !ids.insert(id).second || s.FindInt("revision").value_or(0) < 1 ||
        !s.FindBool("enabled") || !s.FindBool("allFrames") || !m ||
        !s.FindDict("metadata") || *m != *s.FindDict("metadata") ||
        (world != "isolated" && world != "page") ||
        (world == "page" && !m->FindList("grants")->empty()) || !history ||
        history->size() > 5)
      return false;
    for (const auto& previous : *history)
      if (!previous.is_dict() ||
          !ParseMetadata(EnhancementField(previous.GetDict(), "source")))
        return false;
  }
  for (auto [id, dict] : *values) {
    if (!ids.contains(id) || !dict.is_dict() || dict.GetDict().size() > 128 ||
        base::WriteJson(dict).value_or("").size() > 65536)
      return false;
    for (auto [key, value] : dict.GetDict()) {
      const auto* json =
          value.is_dict() ? value.GetDict().FindString("json") : nullptr;
      if (key.empty() || key.size() > 200 || !json || json->size() > 4096 ||
          !base::JSONReader::Read(*json, base::JSON_PARSE_RFC))
        return false;
    }
  }
  return true;
}
void EnhancementStore::Commit(base::DictValue state,
                              bool policy,
                              Completion done) {
  if (!readable_ || !ready_ || writing_) {
    std::move(done).Run(!readable_ ? error_
                                   : "配置正在读取或保存，请稍后重试。");
    RunNext();
    return;
  }
  state.Set("revision", state_.FindInt("revision").value_or(0) + 1);
  auto json = base::WriteJson(state);
  if (!Validate(state) || !json || json->size() > kMaxBytes) {
    std::move(done).Run("配置无效或已超过容量限制。");
    RunNext();
    return;
  }
  if (path_.empty()) {
    state_ = std::move(state);
    if (policy)
      observers_.Notify();
    std::move(done).Run("");
    RunNext();
    return;
  }
  writing_ = true;
  io_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](base::FilePath path, std::string expected,
             std::string bytes) -> std::string {
            std::string current;
            if ((base::PathExists(path) && !base::ReadFileToStringWithMaxSize(
                                               path, &current, kMaxBytes)) ||
                current != expected)
              return "配置已被另一处修改，请重新打开浏览器后再保存。";
            if (!base::CreateDirectory(path.DirName()) ||
                !base::ImportantFileWriter::WriteFileAtomically(path, bytes))
              return "无法保存配置，原设置保持不变。";
            return "";
          },
          path_, disk_bytes_, *json),
      base::BindOnce(
          [](base::WeakPtr<EnhancementStore> self, base::DictValue state,
             std::string bytes, bool policy, Completion done,
             std::string error) {
            if (!self)
              return;
            self->writing_ = false;
            if (error.empty()) {
              self->state_ = std::move(state);
              self->disk_bytes_ = std::move(bytes);
              self->error_.clear();
              if (policy)
                self->observers_.Notify();
            }
            std::move(done).Run(std::move(error));
            if (self)
              self->RunNext();
          },
          weak_.GetWeakPtr(), std::move(state), std::move(*json), policy,
          std::move(done)));
}
void EnhancementStore::RunNext() {
  if (writing_ || queued_.empty())
    return;
  auto next = std::move(queued_.front());
  queued_.pop_front();
  std::move(next).Run();
}
void EnhancementStore::Mutate(const base::DictValue& request, Completion done) {
  if (writing_) {
    queued_.push_back(base::BindOnce(&EnhancementStore::Mutate,
                                     weak_.GetWeakPtr(), request.Clone(),
                                     std::move(done)));
    return;
  }
  auto next = state_.Clone();
  auto error = Prepare(request, next);
  if (!error.empty()) {
    std::move(done).Run(error);
    RunNext();
    return;
  }
  const auto op = EnhancementField(request, "op");
  Commit(std::move(next), op != "reading-preferences" && op != "markdown-site", std::move(done));
}
std::string EnhancementStore::Prepare(const base::DictValue& r,
                                      base::DictValue& next) {
  const std::string op = EnhancementField(r, "op"),
                    id = EnhancementField(r, "id");
  auto* scripts = next.FindList("scripts");
  auto* sites = next.FindList("sites");
  if (op == "markdown-site") {
    if (!next.FindDict("markdownSites"))
      next.Set("markdownSites", base::DictValue());
    if (!r.FindBool("enabled"))
      return "缺少网站预览设置。";
    next.FindDict("markdownSites")
        ->Set(EnhancementField(r, "origin"), Flag(r, "enabled"));
  } else if (op == "reading-preferences") {
    const auto* preferences = r.FindDict("preferences");
    if (!preferences)
      return "阅读外观设置无效。";
    next.Set("readingPreferences", preferences->Clone());
  } else if (op == "site-save") {
    const auto* rule = r.FindDict("rule");
    if (!rule)
      return "网站规则无效。";
    sites->EraseIf([&](const base::Value& v) {
      return EnhancementField(v.GetDict(), "origin") ==
             EnhancementField(*rule, "origin");
    });
    sites->Append(rule->Clone());
  } else if (op == "site-remove") {
    sites->EraseIf([&](const base::Value& v) {
      return EnhancementField(v.GetDict(), "origin") ==
             EnhancementField(r, "origin");
    });
  } else if (op == "disable-all") {
    for (auto& item : *scripts) {
      auto& s = item.GetDict();
      s.Set("enabled", false);
      s.Set("revision", s.FindInt("revision").value_or(0) + 1);
    }
  } else {
    const auto* old = Script(id);
    if (!id.empty() &&
        (!old || old->FindInt("revision") != r.FindInt("revision")))
      return "脚本版本已经变化，请刷新管理器。";
    if (op == "script-remove") {
      if (!old)
        return "脚本不存在。";
      scripts->EraseIf([&](const base::Value& v) {
        return EnhancementField(v.GetDict(), "id") == id;
      });
      next.FindDict("values")->Remove(id);
    } else if (op == "script-site") {
      const auto origin = EnhancementField(r, "origin");
      if (!old || !Flag(*old, "enabled") || !r.FindBool("enabled") ||
          !WebURL(GURL(origin)) ||
          url::Origin::Create(GURL(origin)).Serialize() != origin)
        return "请先授权启用脚本，并选择普通网站。";
      for (auto& item : *scripts) {
        auto& script = item.GetDict();
        if (EnhancementField(script, "id") != id)
          continue;
        if (!script.FindList("disabledOrigins"))
          script.Set("disabledOrigins", base::ListValue());
        auto* disabled = script.FindList("disabledOrigins");
        disabled->EraseIf([&](const base::Value& v) { return v.GetString() == origin; });
        if (!Flag(r, "enabled"))
          disabled->Append(origin);
        script.Set("revision", old->FindInt("revision").value() + 1);
      }
    } else if (op == "script-enable") {
      if (!old || !r.FindBool("enabled"))
        return "启停参数无效。";
      for (auto& item : *scripts)
        if (EnhancementField(item.GetDict(), "id") == id) {
          item.GetDict().Set("enabled", Flag(r, "enabled"));
          item.GetDict().Set("revision", old->FindInt("revision").value() + 1);
        }
    } else if (op == "script-save" || op == "script-rollback") {
      base::DictValue input = r.Clone();
      if (op == "script-rollback") {
        if (!old || old->FindList("history")->empty())
          return "没有可回退版本。";
        input = old->FindList("history")->back().GetDict().Clone();
      }
      const auto source = EnhancementField(input, "source");
      auto metadata = ParseMetadata(source);
      if (!metadata)
        return "脚本元数据、网址或权限不受支持。";
      base::ListValue history;
      if (old) {
        history = old->FindList("history")->Clone();
        if (history.size() >= 5)
          history.erase(history.begin());
        history.Append(base::DictValue()
                           .Set("source", EnhancementField(*old, "source"))
                           .Set("world", EnhancementField(*old, "world"))
                           .Set("allFrames", Flag(*old, "allFrames")));
      }
      const std::string identity =
          old ? id : base::Uuid::GenerateRandomV4().AsLowercaseString();
      scripts->EraseIf([&](const base::Value& v) {
        return EnhancementField(v.GetDict(), "id") == identity;
      });
      scripts->Append(
          base::DictValue()
              .Set("id", identity)
              .Set("revision", old ? old->FindInt("revision").value() + 1 : 1)
              .Set("source", source)
              .Set("metadata", std::move(*metadata))
              .Set("world", EnhancementField(input, "world"))
              .Set("allFrames", Flag(input, "allFrames"))
              .Set("enabled", false)
              .Set("disabledOrigins", old && old->FindList("disabledOrigins")
                                          ? old->FindList("disabledOrigins")->Clone()
                                          : base::ListValue())
              .Set("history", std::move(history)));
    } else
      return "未知操作。";
  }
  return "";
}
std::optional<base::Value> EnhancementStore::Value(
    const std::string& id,
    const std::string& key) const {
  const auto* dict = state_.FindDict("values")->FindDict(id);
  const auto* value = dict ? dict->FindDict(key) : nullptr;
  const auto* json = value ? value->FindString("json") : nullptr;
  return json ? base::JSONReader::Read(*json, base::JSON_PARSE_RFC)
              : std::nullopt;
}
void EnhancementStore::SetValue(const std::string& id,
                                const std::string& key,
                                const base::Value* value,
                                Completion done,
                                int revision) {
  if (writing_) {
    queued_.push_back(base::BindOnce(
        [](base::WeakPtr<EnhancementStore> self, std::string id,
           std::string key, std::optional<base::Value> value, Completion done,
           int revision) {
          if (self)
            self->SetValue(id, key, value ? &*value : nullptr, std::move(done),
                           revision);
        },
        weak_.GetWeakPtr(), id, key,
        value ? std::optional<base::Value>(value->Clone()) : std::nullopt,
        std::move(done), revision));
    return;
  }
  if (revision &&
      (!Script(id) || Script(id)->FindInt("revision") != revision)) {
    std::move(done).Run("脚本授权已经变化。");
    RunNext();
    return;
  }
  if (!Script(id) || key.empty() || key.size() > 200) {
    std::move(done).Run("存储键无效。");
    RunNext();
    return;
  }
  auto next = state_.Clone();
  auto* values = next.FindDict("values");
  if (!values->FindDict(id))
    values->Set(id, base::DictValue());
  if (value) {
    auto json = base::WriteJson(*value);
    if (!json || json->size() > 4096) {
      std::move(done).Run("存储值超过 4 KiB。");
      RunNext();
      return;
    }
    values->FindDict(id)->Set(key, base::DictValue().Set("json", *json));
  } else
    values->FindDict(id)->Remove(key);
  Commit(std::move(next), false, std::move(done));
}
}  // namespace aegis
