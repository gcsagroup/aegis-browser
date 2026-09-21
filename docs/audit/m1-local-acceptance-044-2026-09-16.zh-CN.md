# M1 本地候选044验收

2026-09-16。044完整浏览器构建、211项原生回归及固定App关键流程通过。153内核的pin、140个Chromium补丁、3个V8补丁和overlay已收敛到主仓库，保留恢复副本；收敛后的完整`quality:fast`退出0，日志为`m1-convergence-quality-fast-passed.log`。

## 同一候选的证据

- 产品：Ver 1.1 (044) / 1.1.0.44；内核：153.0.8010.37。
- Chromium HEAD：`e0a52c9a56bd87b8760e7566b259425ca4239050`，完整补丁重放树：`6f6294dfabbb9bfcf69a5a612bad3b2c41334ce5`。
- V8 HEAD：`e3b59f471a4ce044a920369a63e69ae43c4bfdbb`。
- 构建清单SHA-256：`b67fad9941bbb8c44fea9e39f768560db7a89b59a4ea1be44c034e4c7e920e19`。
- 固定App：`/Users/lazy/Applications/GCSA Aegis Test.app`。
- 独立Profile：`/Users/lazy/Library/Application Support/GCSA Aegis Acceptance`。
- 签名仍为原Apple Development身份，Team `HX69X22ZGL`；严格签名验证通过。安装副本只调整独立资料标识后重签，源产物前后核验一致。

构建始终使用同一候选`src/out/AegisRelease`和Ninja。SDK27链接器回补见[独立记录](sdk27-lld-backport-2026-09-15.zh-CN.md)。043单线程链接耗时较长，停止后保留对象及缓存；044将Framework链接及ThinLTO并行改为4，优化不变，复用编译结果后完成347步。最后测试二进制沿用自身原有配置，未降低测试要求。

## 测试与实际操作

| 项目 | 结果与边界 |
|---|---|
| Agent Core | 168项先列名、单次执行全过 |
| GitHub更新器 | 18项先列名、单次执行全过 |
| Actor URL权限 | 25项先列名、单次执行全过；不等于全部Chromium unit_tests |
| 版本、设置、启动 | 关于页显示044，内部版本页确认内核、执行路径和Profile；下载设置可操作；关于页视觉检查正常 |
| 本地摘要 | 原有Qwen模型，114字合成页面输入，正确返回指标42和固定输入/三次测量/中位数方法 |
| Agent只读研究 | 00:53:18–00:53:26完成，结果包含42及准确来源URL |
| 原生下载 | 只新增`aegis-fixture-macos-arm64 (7).bin`，176128字节；界面172 KB完成，SHA-256为`c3f99477218ffb23bc82a11cf41e734062bcb45f27a7aea717202f99ef37532e`；旧文件不变、未执行 |
| 无痕隔离 | 无痕窗口未带入普通任务结果；关闭后专用合成URL在普通History中0行，普通来源1行 |
| 冷重启 | 旧PID23916实际退出、新PID24292启动；模型保留、没有旧任务自动执行 |
| 更新页面 | 显示暂无可用正式版本；不证明线上更新安装链路 |

Linux同一V8源码完整构建及两项原始JS回归已通过，原脚本与断言未改，使用直接单次运行；标准vpython依赖下载超时单列保留，不冒充标准运行器通过。离线签名更新元数据原型14项测试结果沿用，不当作浏览器在线更新集成。

## 安装前发现并解决的问题

安装前首次身份复核失败：新终端默认Node变为24.14.0，而正式构建使用25.2.1。未创建安装副本或替换App。固定为`/opt/homebrew/bin/node`并断言版本与清单相同后，完整输入、构建图、补丁、overlay、产物核验全部通过。未修改清单、源码或跳过校验；失败日志与修复复验均保留。

Computer Use的粘贴调用两次超时，但地址已输入；先回读再提交。一次模拟键入漏掉冒号而打开普通搜索，随后通过地址栏完整赋值纠正，未将搜索结果当版本证据。后续URL输入使用可访问性赋值，均回读验证。

## 主仓库收敛与恢复

精确同步160个差异文件，执行前逐项核对主仓库HEAD、源/目标摘要、权限及未提交冲突为0。没有删除文件、迁移源码或输出。恢复副本在`.artifacts/integration-20260915/m1-main-before-convergence`，旧marker也保留。

本机`.chromium-root`改为现有`upstream-candidate`；其`product`副本冻结为044历史输入，下一版本从主仓库重新冻结。037旧App位于`install-044/previous-installed.app`，037配套Profile备份仍保留；回退前须确认之后新版本的数据兼容性，不直接覆盖新资料。

## 原始记录与未完成范围

- 候选：`validation/full-browser-build.json`、`patch-reapply-044.json`、三组044原生测试日志/JSON及`src/out/AegisRelease/.aegis/build-manifest.json`。
- 主仓库：`.artifacts/integration-20260915/install-044/`中的来源复核、签名、安装、App验收、下载和测试页面记录；`m1-source-convergence.json`记录精确同步。
- 当前证据是本机协作工作流绑定，不是受保护CI签发的可信构建证明，也不是公开发行/公证资格。
- 90次基础任务、100个完整安全场景、M2可信Agent及M3整合流程尚未完成。新任务旧状态、错误页面误完成、失败动作重复等已有负例保留，由M2修复，不用本次摘要冒烟结果覆盖。

收敛门禁首次发现已退出进程组的macOS EPERM竞态，改为只在确认无活进程时视为已停止，真实权限拒绝仍抛错；6项相关回归通过。另修正旧语言测试按Polymer取值的问题，直接执行Lit字段初始化，原12项语言断言通过。旧失败日志保留，最终完整门禁全过。上述脚本修复不改044原生源码或历史构建输入。
