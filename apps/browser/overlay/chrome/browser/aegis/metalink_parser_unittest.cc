// Copyright 2026 GCSA

#include "chrome/browser/aegis/metalink_parser.h"

#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "content/public/test/browser_task_environment.h"
#include "services/data_decoder/public/cpp/test_support/in_process_data_decoder.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

MetalinkParseResult Parse(const std::string& xml) {
  base::RunLoop run_loop;
  MetalinkParseResult result;
  ParseMetalink(xml, base::BindOnce(
                         [](MetalinkParseResult* out, base::OnceClosure done,
                            MetalinkParseResult parsed) {
                           *out = std::move(parsed);
                           std::move(done).Run();
                         },
                         &result, run_loop.QuitClosure()));
  run_loop.Run();
  return result;
}

class MetalinkParserTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
  data_decoder::test::InProcessDataDecoder in_process_data_decoder_;
};

TEST_F(MetalinkParserTest, ParsesSafeMirrorsAndStrongHash) {
  const MetalinkParseResult result = Parse(R"(
    <metalink xmlns="urn:ietf:params:xml:ns:metalink">
      <file name="aegis.bin">
        <size>4096</size>
        <hash type="sha-256">
          0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        </hash>
        <url priority="2">https://mirror-b.example/aegis.bin?token=secret</url>
        <url priority="1">https://mirror-a.example/aegis.bin</url>
      </file>
    </metalink>)");
  ASSERT_TRUE(result.ok) << result.error;
  EXPECT_EQ(result.file_name, "aegis.bin");
  EXPECT_EQ(result.file_size, 4096);
  EXPECT_EQ(result.hash_algorithm, "sha-256");
  ASSERT_EQ(result.mirrors.size(), 2u);
  EXPECT_EQ(result.mirrors[0].url.host(), "mirror-a.example");
  EXPECT_EQ(result.mirrors[1].url.host(), "mirror-b.example");
}

TEST_F(MetalinkParserTest, RejectsPrivateAndCredentialedMirrors) {
  const MetalinkParseResult result = Parse(R"(
    <metalink xmlns="urn:ietf:params:xml:ns:metalink">
      <file name="aegis.bin">
        <hash type="sha-512">0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef</hash>
        <url>http://127.0.0.1/aegis.bin</url>
        <url>http://192.168.1.2/aegis.bin</url>
        <url>https://user:password@example.com/aegis.bin</url>
      </file>
    </metalink>)");
  EXPECT_FALSE(result.ok);
  EXPECT_EQ(result.error, "没有可用的公开 HTTP(S) 镜像");
}

TEST_F(MetalinkParserTest, RejectsTraversalWeakHashAndOversize) {
  EXPECT_FALSE(Parse(R"(
    <metalink xmlns="urn:ietf:params:xml:ns:metalink">
      <file name="../escape.bin">
        <hash type="sha-256">
          0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        </hash>
        <url>https://example.com/a.bin</url>
      </file>
    </metalink>)")
                   .ok);
  EXPECT_FALSE(Parse(R"(
    <metalink xmlns="urn:ietf:params:xml:ns:metalink">
      <file name="a.bin">
        <hash type="sha-1">0123456789abcdef0123456789abcdef01234567</hash>
        <url>https://example.com/a.bin</url>
      </file>
    </metalink>)")
                   .ok);
  EXPECT_EQ(Parse(std::string(1024 * 1024 + 1, 'x')).error,
            "Metalink 文档为空或超过 1 MiB");
}

}  // namespace
}  // namespace aegis
