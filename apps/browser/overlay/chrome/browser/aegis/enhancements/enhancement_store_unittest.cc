// Copyright 2026 GCSA
#include "chrome/browser/aegis/enhancements/enhancement_store.h"
#include "base/base_paths.h"
#include "base/test/bind.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/path_service.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "testing/gtest/include/gtest/gtest.h"
namespace aegis {
namespace {
std::string Script(std::string code = "", std::string grants = "none") {
  return "// ==UserScript==\n// @name 验收脚本\n// @match "
         "https://example.com/*\n// @grant " +
         grants + "\n// ==/UserScript==\n" + code;
}
class EnhancementStoreTest : public testing::Test {
 protected:
  base::test::TaskEnvironment tasks_;
  base::ScopedTempDir directory_;
  void SetUp() override { ASSERT_TRUE(directory_.CreateUniqueTempDir()); }
  std::string Mutate(EnhancementStore& store, base::DictValue value) {
    base::test::TestFuture<std::string> future;
    store.Mutate(value, future.GetCallback());
    return future.Get();
  }
};
TEST_F(EnhancementStoreTest, SharedMatchingVectors) {
  base::FilePath root;
  ASSERT_TRUE(base::PathService::Get(base::DIR_SRC_TEST_DATA_ROOT, &root));
  std::string json;
  ASSERT_TRUE(base::ReadFileToString(
      root.AppendASCII("chrome/browser/resources/aegis/enhancements_shared/"
                       "tests/matching-vectors.json"),
      &json));
  auto vectors = base::JSONReader::ReadList(json, base::JSON_PARSE_RFC);
  ASSERT_TRUE(vectors);
  for (const auto& item : *vectors) {
    const auto& v = item.GetDict();
    EXPECT_EQ(EnhancementStore::Matches(EnhancementField(v, "pattern"),
                                        GURL(EnhancementField(v, "url"))),
              v.FindBool("matches"))
        << EnhancementField(v, "url");
  }
}
TEST_F(EnhancementStoreTest, MetadataAndFrameAuthorization) {
  auto metadata = EnhancementStore::ParseMetadata(Script());
  ASSERT_TRUE(metadata);
  auto script = base::DictValue()
                    .Set("metadata", metadata->Clone())
                    .Set("allFrames", false);
  EXPECT_TRUE(EnhancementStore::Applies(
      script, GURL("https://example.com/article"), true));
  EXPECT_FALSE(EnhancementStore::Applies(
      script, GURL("https://example.com/article"), false));
  script.Set("allFrames", true);
  EXPECT_TRUE(EnhancementStore::Applies(
      script, GURL("https://example.com/article"), false));
  EXPECT_FALSE(
      EnhancementStore::Applies(script, GURL("chrome://settings/"), true));
  EXPECT_FALSE(
      EnhancementStore::ParseMetadata(Script("", "GM_xmlhttpRequest")));
  EXPECT_FALSE(EnhancementStore::ParseMetadata("alert(1);\n" + Script()));
  EXPECT_FALSE(
      EnhancementStore::ParseMetadata(Script() + std::string(65537, 'x')));
}
TEST_F(EnhancementStoreTest, PersistenceDraftVersionAndRollback) {
  const auto path = directory_.GetPath().AppendASCII("scripts.json");
  EnhancementStore store(path);
  tasks_.RunUntilIdle();
  ASSERT_TRUE(store.ready());
  EXPECT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-save")
                              .Set("source", Script("document.title='first';"))
                              .Set("world", "isolated")),
            "");
  const auto& first = store.state().FindList("scripts")->front().GetDict();
  const auto id = EnhancementField(first, "id");
  EXPECT_EQ(first.FindBool("enabled"), false);
  EXPECT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-enable")
                              .Set("id", id)
                              .Set("revision", 1)
                              .Set("enabled", true)),
            "");
  EXPECT_NE(Mutate(store, base::DictValue()
                              .Set("op", "script-enable")
                              .Set("id", id)
                              .Set("revision", 1)
                              .Set("enabled", false)),
            "");
  EXPECT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-save")
                              .Set("id", id)
                              .Set("revision", 2)
                              .Set("source", Script("document.title='second';"))
                              .Set("world", "isolated")),
            "");
  EXPECT_EQ(store.Script(id)->FindBool("enabled"), false);
  EXPECT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-rollback")
                              .Set("id", id)
                              .Set("revision", 3)),
            "");
  EXPECT_EQ(EnhancementField(*store.Script(id), "source"),
            Script("document.title='first';"));
  EnhancementStore reopened(path);
  tasks_.RunUntilIdle();
  EXPECT_EQ(reopened.state(), store.state());
  EnhancementStore private_store{base::FilePath()};
  EXPECT_TRUE(private_store.state().FindList("scripts")->empty());
}
TEST_F(EnhancementStoreTest, CorruptOrExternallyChangedFileIsNotOverwritten) {
  const auto path = directory_.GetPath().AppendASCII("scripts.json");
  EnhancementStore store(path);
  tasks_.RunUntilIdle();
  ASSERT_TRUE(base::WriteFile(path, "broken"));
  EXPECT_NE(Mutate(store, base::DictValue()
                              .Set("op", "script-save")
                              .Set("source", Script())
                              .Set("world", "isolated")),
            "");
  EnhancementStore unreadable(path);
  tasks_.RunUntilIdle();
  EXPECT_FALSE(unreadable.error().empty());
  EXPECT_NE(Mutate(unreadable, base::DictValue().Set("op", "disable-all")), "");
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &bytes));
  EXPECT_EQ(bytes, "broken");
}
TEST_F(EnhancementStoreTest, StorageIdentityAndValueQuota) {
  EnhancementStore store{base::FilePath()};
  ASSERT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-save")
                              .Set("source", Script())
                              .Set("world", "isolated")),
            "");
  const auto id = EnhancementField(
      store.state().FindList("scripts")->front().GetDict(), "id");
  base::Value value(42);
  base::test::TestFuture<std::string> future;
  store.SetValue(id, "x", &value, future.GetCallback());
  EXPECT_EQ(future.Get(), "");
  EXPECT_EQ(store.Value(id, "x"), base::Value(42));
  EXPECT_FALSE(store.Value("another", "x"));
  base::Value huge(std::string(4097, 'x'));
  base::test::TestFuture<std::string> rejected;
  store.SetValue(id, "x", &huge, rejected.GetCallback());
  EXPECT_NE(rejected.Get(), "");
  EXPECT_EQ(store.Value(id, "x"), base::Value(42));
}
TEST_F(EnhancementStoreTest, QueuedWritesKeepValuesAndRejectRevokedRevision) {
  EnhancementStore store(directory_.GetPath().AppendASCII("queue.json"));
  tasks_.RunUntilIdle();
  ASSERT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "script-save")
                              .Set("source", Script())
                              .Set("world", "isolated")),
            "");
  const auto id = EnhancementField(
      store.state().FindList("scripts")->front().GetDict(), "id");
  base::Value one(1), two(2);
  base::test::TestFuture<std::string> a, b, c, d;
  store.SetValue(id, "a", &one, a.GetCallback(), 1);
  store.SetValue(id, "b", &two, b.GetCallback(), 1);
  store.Mutate(base::DictValue().Set("op", "disable-all"), c.GetCallback());
  store.SetValue(id, "c", &two, d.GetCallback(), 1);
  EXPECT_EQ(a.Get(), "");
  EXPECT_EQ(b.Get(), "");
  EXPECT_EQ(c.Get(), "");
  EXPECT_NE(d.Get(), "");
  EXPECT_EQ(store.Value(id, "a"), base::Value(1));
  EXPECT_EQ(store.Value(id, "b"), base::Value(2));
  EXPECT_FALSE(store.Value(id, "c"));
  EXPECT_EQ(Mutate(store, base::DictValue()
                              .Set("op", "markdown-site")
                              .Set("origin", "https://example.com")
                              .Set("enabled", true)),
            "");
  EXPECT_NE(Mutate(store, base::DictValue()
                              .Set("op", "markdown-site")
                              .Set("origin", "file:///tmp")
                              .Set("enabled", true)),
            "");
}

TEST_F(EnhancementStoreTest, SitePausePreservesGlobalGrantValuesAndOldSchema) {
  EnhancementStore store(base::FilePath{});
  ASSERT_TRUE(Mutate(store, base::DictValue().Set("op", "script-save")
      .Set("source", Script()).Set("world", "isolated")).empty());
  const auto id = EnhancementField(store.state().FindList("scripts")->front().GetDict(), "id");
  ASSERT_TRUE(Mutate(store, base::DictValue().Set("op", "script-enable")
      .Set("id", id).Set("revision", 1).Set("enabled", true)).empty());
  auto old_schema = store.state().Clone();
  old_schema.FindList("scripts")->front().GetDict().Remove("disabledOrigins");
  EXPECT_TRUE(EnhancementStore::Validate(old_schema));
  auto request = base::DictValue().Set("op", "script-site").Set("id", id)
      .Set("revision", 2).Set("origin", "https://example.com").Set("enabled", false);
  ASSERT_TRUE(Mutate(store, request.Clone()).empty());
  EXPECT_EQ(store.Script(id)->FindBool("enabled"), true);
  EXPECT_TRUE(EnhancementStore::PausedAt(*store.Script(id), GURL("https://example.com/article")));
  EXPECT_FALSE(EnhancementStore::PausedAt(*store.Script(id), GURL("https://sub.example.com/")));
  EXPECT_FALSE(EnhancementStore::PausedAt(*store.Script(id), GURL("http://example.com/")));
  EXPECT_FALSE(Mutate(store, request.Clone()).empty());
  request.Set("revision", 3);
  request.Set("enabled", true);
  ASSERT_TRUE(Mutate(store, request.Clone()).empty());
  EXPECT_FALSE(EnhancementStore::PausedAt(*store.Script(id), GURL("https://example.com/")));
  request.Set("revision", 4);
  request.Set("origin", "file:///tmp");
  EXPECT_FALSE(Mutate(store, request.Clone()).empty());
}
TEST_F(EnhancementStoreTest, ReadingPreferencesDoNotRevokeScriptsOrGrantImages) {
  EnhancementStore store(base::FilePath{});
  int changed = 0;
  auto subscription = store.Observe(base::BindLambdaForTesting([&] { ++changed; }));
  auto preferences = base::DictValue().Set("theme", "dark").Set("family", "serif")
      .Set("font", 19).Set("spacing", 180).Set("width", 820);
  EXPECT_TRUE(Mutate(store, base::DictValue().Set("op", "reading-preferences")
      .Set("preferences", preferences.Clone())).empty());
  EXPECT_EQ(changed, 0);
  EXPECT_FALSE(store.state().contains("remoteImages"));
  preferences.Set("font", 200);
  EXPECT_FALSE(Mutate(store, base::DictValue().Set("op", "reading-preferences")
      .Set("preferences", preferences.Clone())).empty());
  EXPECT_EQ(store.state().FindDict("readingPreferences")->FindInt("font"), 19);
}

}  // namespace
}  // namespace aegis
