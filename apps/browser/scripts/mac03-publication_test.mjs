import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

// Execute the producer's actual C++ publication statements, with only Chromium
// plumbing replaced. File writes/readback/removal are real; a controlled clock
// makes each I/O boundary cross the existing absolute deadline deterministically.
const source = readFileSync(new URL('../overlay/chrome/browser/aegis/agent/aegis_agent_browsertest.cc', import.meta.url), 'utf8');
const begin = source.indexOf('  std::string serialized;\n  ASSERT_TRUE(base::JSONWriter::Write(bundle, &serialized));');
// The cleanup guard is inserted immediately after the same declaration.
const guardedBegin = source.indexOf('  std::string serialized;\n  base::ScopedClosureRunner');
const start = begin >= 0 ? begin : guardedBegin;
assert.ok(start >= 0, 'MAC03 publication entry must be unambiguous');
const end = source.indexOf('  // External consumer performs post-child', start);
assert.ok(end > start, 'MAC03 publication end must be present');
const publication = source.slice(start, end);
const directory = mkdtempSync(join(tmpdir(), 'aegis-mac03-publication-'));
const cpp = join(directory, 'publication.cc');
const binary = join(directory, 'publication');
writeFileSync(cpp, String.raw`
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <string>
#include <utility>
namespace fs = std::filesystem;
static long long now_ns = 100;
static std::string mode;
static void Delay(const char* phase) { if (mode == phase) now_ns = 200; }
namespace base {
using FilePath = fs::path;
struct DictValue {};
template <typename F, typename A> auto BindOnce(F f, A a) {
  return [f, a] { f(a); };
}
class ScopedClosureRunner {
 public:
  template <typename F> explicit ScopedClosureRunner(F f) : cleanup_(f) {}
  ~ScopedClosureRunner() { if (cleanup_) cleanup_(); }
  auto Release() { return std::exchange(cleanup_, {}); }
 private:
  std::function<void()> cleanup_;
};
static bool PathExists(const FilePath& path) { return fs::exists(path); }
static bool DeleteFile(const FilePath& path) { return fs::remove(path); }
static bool IsDirectoryEmpty(const FilePath& path) { return fs::is_empty(path); }
struct JSONWriter {
  static bool Write(const DictValue&, std::string* out) {
    *out = "{\"terminal\":\"complete\"}";
    Delay("serialize");
    return mode != "serialize-failure";
  }
};
struct ImportantFileWriter {
  static bool WriteFileAtomically(const FilePath& path, const std::string& bytes) {
    const FilePath temp = path.string() + ".pending";
    { std::ofstream stream(temp); stream << bytes; if (!stream) return false; }
    fs::rename(temp, path);
    Delay("write");
    return mode != "write-failure";
  }
};
static bool ReadFileToStringWithMaxSize(const FilePath& path,
                                      std::string* out, size_t limit) {
  std::ifstream stream(path);
  if (!stream) return false;
  out->assign(std::istreambuf_iterator<char>(stream), {});
  Delay("read");
  if (mode == "read-mismatch") *out = "different";
  return out->size() <= limit && mode != "read-failure";
}
}  // namespace base
struct Observer {
  bool CheckDeadline() const { return now_ns < 200; }
  bool FinalEmpty() const { return true; }
  const char* error() const { return "deadline"; }
};
static bool Mac03PhysicalPath(const fs::path& path, bool directory) {
  return !fs::is_symlink(path) &&
      (directory ? fs::is_directory(path) : fs::is_regular_file(path));
}
struct Assertion {
  template <typename T> Assertion& operator<<(const T&) { return *this; }
};
#define ASSERT_TRUE(value) if (!(value)) return false; else Assertion()
#define ASSERT_LE(a, b) ASSERT_TRUE((a) <= (b))
#define ASSERT_EQ(a, b) ASSERT_TRUE((a) == (b))
static bool Publish(const fs::path& evidence_dir, const fs::path& final_path) {
  Observer observer;
  base::DictValue bundle;
` + publication + String.raw`
  return true;
}
int main(int argc, char** argv) {
  if (argc != 3) return 2;
  mode = argv[1];
  if (mode == "already-expired") now_ns = 200;
  const fs::path directory(argv[2]);
  fs::create_directory(directory);
  const fs::path final_path = directory / "MAC03-independent-v2.json";
  const bool accepted = Publish(directory, final_path);
  std::cout << accepted << " " << fs::exists(final_path) << "\n";
}
`);
const compiler = spawnSync(process.env.CXX || 'clang++',
  ['-std=c++20', '-Wall', '-Wextra', cpp, '-o', binary], {encoding: 'utf8'});
assert.equal(compiler.status, 0, compiler.stderr);
test.after(() => rmSync(directory, {recursive: true, force: true}));

for (const [mode, expected] of [
  ['success', '1 1'],
  ['already-expired', '0 0'],
  ['serialize', '0 0'],
  ['write', '0 0'],
  ['read', '0 0'],
  ['serialize-failure', '0 0'],
  ['write-failure', '0 0'],
  ['read-failure', '0 0'],
  ['read-mismatch', '0 0'],
]) {
  test('MAC03 publication ' + mode + ' retains only accepted evidence', () => {
    const result = spawnSync(binary, [mode, join(directory, mode)], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), expected);
  });
}
