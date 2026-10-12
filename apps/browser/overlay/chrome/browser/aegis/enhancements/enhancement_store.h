// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ENHANCEMENTS_ENHANCEMENT_STORE_H_
#define CHROME_BROWSER_AEGIS_ENHANCEMENTS_ENHANCEMENT_STORE_H_

#include <deque>
#include <optional>
#include <string>
#include "base/callback_list.h"
#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "base/values.h"
#include "url/gurl.h"
class Profile;
namespace aegis {
// 每个 Profile 一个实例。私密配置不读取或写入普通配置文件。
class EnhancementStore : public base::SupportsUserData::Data {
 public:
  static EnhancementStore* Get(Profile* profile);
  explicit EnhancementStore(base::FilePath path);
  ~EnhancementStore() override;
  const base::DictValue& state() const { return state_; }
  const std::string& error() const { return error_; }
  const base::DictValue* Script(const std::string& id) const;
  const base::DictValue* Rule(const GURL& url) const;
  base::CallbackListSubscription Observe(base::RepeatingClosure callback);
  // 操作参数只来自受信任的管理界面；源代码元数据仍由原生重解析。
  using Completion = base::OnceCallback<void(std::string)>;
  bool ready() const { return ready_; }
  void Mutate(const base::DictValue& request, Completion done);
  void SetValue(const std::string& id,
                const std::string& key,
                const base::Value* value,
                Completion done,
                int revision = 0);
  std::optional<base::Value> Value(const std::string& id,
                                   const std::string& key) const;
  static std::optional<base::DictValue> ParseMetadata(
      const std::string& source);
  static bool Matches(const std::string& pattern, const GURL& url);
  static bool Applies(const base::DictValue& script, const GURL& url, bool top);
  static bool Validate(const base::DictValue& state);

 private:
  void Commit(base::DictValue state, bool policy, Completion done);
  void RunNext();
  std::string Prepare(const base::DictValue& request, base::DictValue& next);
  base::FilePath path_;
  std::string disk_bytes_;
  std::string error_;
  bool readable_ = true;
  bool ready_ = true;
  bool writing_ = false;
  std::deque<base::OnceClosure> queued_;
  scoped_refptr<base::SequencedTaskRunner> io_;
  base::DictValue state_;
  base::RepeatingClosureList observers_;
  base::WeakPtrFactory<EnhancementStore> weak_{this};
};
std::string EnhancementField(const base::DictValue& value,
                             std::string_view key);
}  // namespace aegis
#endif
