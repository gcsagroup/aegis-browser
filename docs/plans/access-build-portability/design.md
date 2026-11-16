# Access 共享核心构建设计

- **源码归属。** 在 `apps/browser/overlay/components/aegis_access` 维护源清单。CMake 编译独立库和测试程序，GN 保持现有 target 名称和依赖边界、直接编译同一组源码。浏览器不链接由独立工具链预编译的库。
- **依赖方向。** 路由决策、规则组、归属、派发、已发布状态和代际计数进入独立核心。依赖 Chromium net/url 的规则匹配、代理适配、Profile 与 Mojo 桥接留在 Chromium；另外的 SOCKS5 解析器由后续切片加入。
- **构建输入。** 清单使用显式相对路径。CMake 通过主机 Python 生成相同的向量，输出留在构建目录。覆盖率沿用现有脚本及 11 个生产单元，测试辅助代码不进入生产库。
- **平台工具链。** CMake 最低 3.21，单独记录实际工具版本。Windows 使用 x64 Visual Studio 环境中的 clang-cl 和 Windows SDK；Android 使用 NDK 的 CMake 工具链，独立测试 API 先取 26，有 SDK/ABI 变化时重新绑定证据。这些预设只约定本任务的测试目标。
- **补丁运输。** 桌面基线为 155.0.8059.80 / `43a195105613ac83c21d3f14de279f4a045c7da0`，Android 为 155.0.8059.79 / `a49e2e3d4addfd84e765b52afe230bedb81096db`。两条有序补丁序列分别交付相同的清单和接线。
- **平台运行。** Windows 后续实现原生进程、句柄和权限管理。Android 后续先验证内嵌桥接与打包进程的可行性，再决定生命周期与打包方式。Xray 资产和工具链单独管理。

从 `apps/browser/access-cmake` 执行以下命令。Chromium 的 overlay 和补丁只交付 GN 接线与共享清单。Windows 选择 x64 Visual Studio Developer Shell，确认 `clang-cl` 和 Ninja 可用。Android 设置 `ANDROID_NDK_HOME`，连接匹配 ABI 的设备，并用 `ANDROID_SERIAL` 明确选定测试设备。

```sh
cmake --preset macos-arm64
cmake --build out/macos-arm64
ctest --test-dir out/macos-arm64 --no-tests=error --output-on-failure
```

Windows 使用 `windows-x64`；Android 设备使用 `android-arm64`，x86_64 模拟器使用 `android-x64`。目录名对应预设。Android 的 CTest 会通过 adb 复制并执行测试，收集退出码并清除设备上的临时文件。

Android runner 从本地 `ADB` 路径或 `PATH` 查找 SDK 的 `adb`/`adb.exe`，解析为绝对可执行文件；`ADB` 不接受附带参数的命令、其他程序或指向其他程序的符号链接。工具链配置属于本机信任边界，设备输出不能选择主机程序。`ANDROID_SERIAL` 继续传给 adb，并以查询到的序列号固定后续调用。主机不使用 shell；远端 shell 只使用固定操作和经严格校验的临时目录。离线验证运行 `python3 -B run_android_test_test.py`，使用临时假 adb，不连接设备，并进入现有脚本质量门。

Android 原序列包含六个旧版核心文件。Android 补丁同步共享核心源码，保留原有 Chromium 接入层。独立测试从产品仓库的 overlay 构建。两个补丁序列的投影回放检查确保清单和共享文件逐字节一致。
