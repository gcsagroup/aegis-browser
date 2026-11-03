# Windows 安装流程

双击 GCSA Aegis 安装包后，窗口显示“正在准备安装”“正在安装”和最终结果。
安装器使用活动进度条，因为解压和系统安装步骤没有统一的总进度，界面不显示估算百分比。
安装期间可以最小化窗口；关闭入口在安装完成后恢复，避免中断文件提交。

首次安装、同版本修复及升级成功后，安装器自动打开浏览器，完成窗口随后收起。
启动使用 Chromium 的桌面用户降权入口，目标固定为实际安装目录中的浏览器。
启动失败会明确提示从桌面快捷方式打开，不把已经完成的安装误报成失败。
安装失败则保留错误代码和关闭按钮；不会自动打开浏览器。
成功后自动打开的交互与 [Chrome 的 Windows 安装流程](https://support.google.com/chrome/answer/95346?hl=zh-Hans)一致。

自动部署使用 `--silent` 或 `--unattended`：不显示安装窗口，也不打开浏览器。
兼容 `/silent`、`/S`；`--update` 与卸载模式也不显示交互安装窗口。
`--do-not-launch-chrome` 和安装首选项中的禁止启动设置始终优先。

## 开发验证

实现位于 `chrome/installer/mini_installer/aegis_install_ui.*`，窗口仅负责展示状态；
安装流程和退出码继续由 Chromium setup 管理。启动策略位于
`chrome/installer/setup/aegis_launch_policy.h`，通过补丁系列应用到 Chromium 源码。

在已配置的 Windows 构建区构建 `mini_installer` 与 `setup_unittests`，执行：

```powershell
out/AegisRelease/setup_unittests.exe --gtest_filter="AegisInstallUiTest.*:AegisLaunchPolicyTest.*:MiniInstallerConfigurationTest.*" --test-launcher-jobs=1
```

回归覆盖静默、安装窗口阶段、成功自动关闭、失败等待确认、同版本修复后的启动、
禁止启动参数与失败状态。还需检查真实窗口、安装包哈希和签名状态。
构建、夹具和策略测试通过不等于在目标用户设备完成安装验收。
