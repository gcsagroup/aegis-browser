> 2026-09-16后续结果：044完整浏览器构建、211项原生回归和固定App关键验收通过，见[044验收](m1-local-acceptance-044-2026-09-16.zh-CN.md)。下文保留回补及重试过程。

# SDK 27 链接器回补记录

当前结论：同版本 LLVM 的最小回补已构建并通过针对性验证，已安装到本机候选工具链。Ver 1.1 (044) 完整浏览器正在继续构建，固定测试 App 保持037；本记录不代表新浏览器或发行验收通过。

## 问题与处理

用户完成 Xcode 27 许可后，SDK、Clang 及 Chromium 的 SDK 查询均可用。040 在 Rust 构建脚本链接时失败：原 LLD 不能解析 SDK `.tbd` 的 `arm64e.x1-macos` 目标，报 `malformed file`，继而报告系统符号未定义。

采用 [LLVM 上游修复 b8007a8e4020](https://chromium.googlesource.com/external/github.com/llvm/llvm-project/+/b8007a8e4020b8bca2b12e941660e10bf5bf6716)：在 Chromium 原绑定的 LLVM 源码 `20e97c4b113b79586c29ac57738548939a34d22e` 上应用单个完整补丁，构建 LLD 及回归所需工具。没有更改 Apple SDK、Chromium 编译器、浏览器 LTO 配置或权限检查。

固定依赖工作目录：`/Users/lazy/Projects/GCSA-aegis-build/upstream-candidate/toolchain-lld-041`。目录名保留首次尝试编号，实际成功尝试对应043，避免每次重试创建另一份依赖。

| 输入或产物 | SHA256 |
|---|---|
| 同版本 LLVM 源码包 | `402868bfcf3489629d8bf0aa607c6141df4d28803e7aafb1e46d87cec0cf9fab` |
| 上游完整补丁 | `4cd628adc412e6984499fd3bb7bcdae963cb617e9708d514c64264ae06809bf7` |
| 原 LLD | `6a23f8ae8e5b2fd87814aaab188ee49ba022693905108bc78ff038fe55e2b581` |
| 新 LLD | `026501c719b76a045a706ecf9078f64fdaeaf2d568431c6fbb5ca730ac2db5e6` |
| 保持不变的 Clang | `70efde6fd29b79dd209f99a1007fffadf9fb780d5650e2d0d693fd5fb196fbfc` |

## 验证结果

1. CMake 配置及2,174步构建退出0。上游补丁完整应用检查通过。
2. 原始 `lld/test/MachO/arm64-x1.s`：同一输入下旧 LLD 报错，新 LLD 成功。
3. 原始 `file-headers-arm64.test` 的 ALL、V8、ARM64E、ARM64E.X1 四组完整 FileCheck 断言，以及 `macho-arm64e_x1.test` 通过。
4. 原 Chromium Clang 与真实 SDK27：旧 LLD 复现错误，新 LLD 链接成功；生成程序实际运行输出 `aegis-sdk27-lld-ok`，退出0。
5. 043 的真实 Chromium Ninja 构建中，原失败 Rust 目标已成功链接，后续构建脚本执行步骤也完成。完整浏览器依赖仍在重编。

第一次测试执行出现日志名称重复，保留该轮为 `tests-043-log-collision-attempt1`，修正名称后重新完整执行，未改变断言；两轮均通过。当前逐命令证据为 `tests-043/result.json`。这不是 LLVM 全套回归，也不等同于 Chromium 原生或实机验收。

## 安装与恢复

执行器位于候选目录：`run-lld-backport-build.py`、`verify-lld-backport.py`、`install-lld-backport.py`。它们使用已有测试锁；安装额外持有候选输出锁，校验测试结果和新旧摘要后原子替换 `src/third_party/llvm-build/Release+Asserts/bin/lld`，保留 `ld64.lld` 等入口链接。

原文件保存为工作目录的 `original-lld`。回补来源写入工具链根目录的 `aegis-lld-backport.json`，并保留 `install-result.json`；身份脚本检查该记录与实际 LLD、Clang 内容一致，将 LLD 和来源记录纳入构建输入。若恢复原 LLD，应在所有编译停止且持有相同锁时，核对原文件摘要后恢复，并归档回补记录，不能让记录与二进制不一致。

新构建工具依赖本机 Homebrew zstd，依赖名称及摘要已记录。构建出现该库最低系统版本为26的警告，因此只认定此工具在当前主机可用；它不随浏览器 App 分发，也不证明工具能在 macOS13运行。更换主机、更新依赖或重新获取 Chromium 工具链后，需要重新核对或重做回补，不视为可移植的正式工具链发行。

## 失败记录与容量

041 配置缺少 libc 公共头文件，已从同一源码包补齐。042 配置实际完成，但容量统计碰到临时目录消失而异常退出；已修正为仅此类竞态最多重读3次，其他错误或持续失败仍停止构建并回收子进程。历史结果和日志保留为 `attempt1`、`attempt2`。

当前限制为系统重要用途可用容量至少30GiB、直接空闲至少8GiB，LLD工作目录另限3GiB，持续监测。只删除用户已确认的旧目录；没有通过改写 SDK、放宽产品测试或追加删除来解决此次链接错误。

## 044资源配置调整

043全部前置检查通过，主体与测试源已编译，单线程大链接持续约半小时后主动停止；日志、对象和缓存全部保留。044将既有链接和ThinLTO限制改为4线程，GN实际参数已核验，优化等级未变。完整进程树停止覆盖链接封装的新进程组，3项真实进程测试、2条驱动异常路径及quality:fast通过。044重新冻结输入后继续构建，固定App仍037。

当前主机18核、128GiB，原单线程链接器RSS约12GiB，打开数值句柄3个，软限制1048575。中止前核对Ninja与链接封装两个独立进程组；新停止逻辑还验证忽略TERM后强制停止、保留无关进程。证据为validation/link-parallelism-transition-043.json、validation/link-flags-044.txt和仓库build-stop-integration-tests.json。
