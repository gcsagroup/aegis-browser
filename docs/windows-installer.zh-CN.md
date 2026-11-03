# Windows 安装流程

双击 GCSA Aegis 安装包后，窗口仅展示品牌、进度条和一行当前状态。
界面使用无系统边框的居中白色窗口，不显示标题栏、关闭或最小化图标，顶部留白可拖动。
安装期间不能关闭以免中断文件提交；成功后窗口自动收起，失败时才显示“关闭”按钮。

界面采用居中品牌图标、深色标题、青蓝色细进度条与简短阶段提示。
成功时显示完成状态，失败时隐藏活动条、保留错误码并显示关闭按钮。
关闭按钮使用系统 GDI+ 抗锯齿圆角，无外围描边；悬停、按下与键盘焦点使用内部反馈。
保留原生按钮的 Tab、空格和回车操作，图形资源不足时退回系统 GDI 绘制。
文字、图标和间距随所在屏幕 DPI 同步缩放；高对比度和关闭动画遵循 Windows 设置。
保留原生文本、进度控件及失败时可键盘操作的关闭按钮，供辅助功能读取。

百分比表示整个安装过程的预估完成量，保持单调、不因切换步骤而清零：

- 准备、解压、展开文件、安装事务、配置及收尾分别占据固定进度区间。
  解压与安装是主要权重；阶段实测字节数和已成功执行的事务数用于校准整体预估。
- 没有可靠分母时按耗时保守推进，不越过当前步骤的预算；进度不用于推算剩余秒数。
- 显示值平滑接近估计值，迟到或倒退的阶段消息不能让进度倒退。
  回滚时停止推进，失败结果不能被迟到的消息覆盖。

安装期间统一显示“正在安装”和整体百分比，最多显示 99%；
只有 setup 的真实成功退出码才能令窗口显示“安装完成”和满进度条。
解码完成不代表校验、文件提交或整次安装成功，失败不能被进度消息覆盖。
进度条背景、轨道和前景先在内存中合成后一次提交；进度更新只使进度条和变化的
状态文字重绘，父窗口擦除排除子控件，避免整页及进度条闪烁。

解压文件存放在 Windows 指定的临时目录中（普通用户通常为 `%TEMP%`），
每次安装使用独立的随机子目录，不在安装包旁边生成临时文件。
默认在安装结束后清理本次释放的文件；临时目录不可用时明确报错，不回退到安装包目录。

首次安装、同版本修复及升级成功后，安装器自动打开浏览器，完成窗口随后收起。
启动使用 Chromium 的桌面用户降权入口，目标固定为实际安装目录中的浏览器。
启动失败会明确提示从桌面快捷方式打开，不把已经完成的安装误报成失败。
安装失败则保留错误代码和关闭按钮；不会自动打开浏览器。
setup 返回 3（已打开现有版本）时显示“已打开现有版本（本次未执行安装）”，
隐藏进度条并自动收起，不显示安装成功、100% 或错误；窗口不可用时也不弹错误框。
自动收起计时器创建失败时直接关闭窗口，避免安装线程永久等待。
成功后自动打开的交互与 [Chrome 的 Windows 安装流程](https://support.google.com/chrome/answer/95346?hl=zh-Hans)一致。

自动部署使用 `--silent` 或 `--unattended`：不显示安装窗口，也不打开浏览器。
兼容 `/silent`、`/S`；`--update` 与卸载模式也不显示交互安装窗口。
`--do-not-launch-chrome` 和安装首选项中的禁止启动设置始终优先。

## 开发验证

实现位于 `chrome/installer/mini_installer/aegis_install_ui.*`，窗口仅负责展示状态；
安装流程和退出码继续由 Chromium setup 管理。启动策略位于
`chrome/installer/setup/aegis_launch_policy.h`，通过补丁系列应用到 Chromium 源码。
跨进程进度协议位于 `chrome/installer/aegis_install_progress.h`：每次安装使用独立的
128 位随机名称、当前会话命名空间和默认 DACL，句柄不继承，不在磁盘写进度文件。
共享数据只有原子的阶段与百分比，不携带命令、路径或成功判定；连接不可用时保留状态展示。

在已配置的 Windows 构建区构建 `mini_installer`、`setup_unittests` 与
`installer_util_unittests`，执行：

```powershell
out/AegisRelease/setup_unittests.exe --gtest_filter="AegisInstallUiTest.*:AegisOverallProgressTest.*:AegisInstallProgressTest.*:AegisLaunchPolicyTest.*:MiniInstallerConfigurationTest.*:MiniInstallerTest.WorkDir*:*SetupUnpackArchive*" --test-launcher-jobs=1
out/AegisRelease/installer_util_unittests.exe --gtest_filter="LzmaUtilTest.*:WorkItemListTest.*" --test-launcher-jobs=1
```

回归覆盖静默、安装窗口阶段、成功自动关闭、失败等待确认、同版本修复后的启动、
禁止启动参数与失败状态。还需检查真实窗口、安装包哈希和签名状态。
构建、夹具和策略测试通过不等于在目标用户设备完成安装验收。

界面回归还覆盖 100%、125%、150%、200% DPI 下的控件边界与最长错误码文字，
以及无边框/无标题区按钮、拖动命中、整体进度跨步骤不清零、未知耗时预算、
回滚冻结、时钟倒退和无效数据处理。重绘观察器验证连续进度更新不会擦除整窗或重画品牌区域。
进度回归覆盖子进程传递、名称碰撞和损坏数据、文件及内存解包、坏包失败、事务完成量与回滚。
最终结果不会被迟到的安装阶段消息覆盖。视觉预览直接链接产品窗口实现，
不执行安装；完成状态的截图停留时间仅由独立预览夹具控制。

临时目录回归使用 `MiniInstallerTest.WorkDir*`，覆盖中文/空格路径、独立目录、
私有 ACL、清理边界及目录缺失、路径为文件、路径过长的失败场景。
目录选择优先动态调用 [GetTempPath2W](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppath2w)，
仅在旧系统没有该 API 时兼容 GetTempPathW；保留 Windows 对 SYSTEM 临时目录的权限选择。
