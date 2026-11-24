// Copyright 2026 The Aegis Browser Authors
// Windows 卸载 UI 的独立 Views 测试入口；加载产品语言与图标，不运行浏览器或 setup。

#include "base/base_paths.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/path_service.h"
#include "mojo/core/embedder/embedder.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/views/views_test_suite.h"

namespace {
class UninstallTestSuite : public views::ViewsTestSuite {
 public:
  using views::ViewsTestSuite::ViewsTestSuite;

 protected:
  void Initialize() override {
    views::ViewsTestSuite::Initialize();
    base::FilePath directory;
    CHECK(base::PathService::Get(base::DIR_EXE, &directory));
    auto& resources = ui::ResourceBundle::GetSharedInstance();
    const auto locale =
        base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("lang");
    CHECK(!resources.ReloadLocaleResources(locale.empty() ? "en-US" : locale)
               .empty());
    resources.AddDataPackFromPath(directory.AppendASCII("resources.pak"),
                                  ui::kScaleFactorNone);
  }
};
}  // namespace

int main(int argc, char** argv) {
  mojo::core::Init();
  return UninstallTestSuite(argc, argv).RunTests();
}
