# Windows 产品安装身份

从 086 内部候选起，Aegis 使用独立的安装目录、用户资料和系统注册身份，避免覆盖原版 Chromium。以下标识属于长期产品身份，不能随版本号、构建时间或机器变化。

产品显示名称采用 **Aegis Browser**。本次显示名更新保留以下 Windows 安装、资料与策略身份，继续读取已有用户资料和管理策略。

- 用户级安装：`%LOCALAPPDATA%\GCSA Aegis\Application\chrome.exe`。
- 系统级安装：`%PROGRAMFILES%\GCSA Aegis\Application\chrome.exe`，实际位置遵循 Windows 安装模式。
- 默认资料：`%LOCALAPPDATA%\GCSA Aegis\User Data`。
- 快捷方式名称：`GCSA Aegis`；应用标识：`app.gcsa.aegis`。
- HTML/PDF 注册前缀：`AegisHTM`、`AegisPDF`；直接启动协议：`aegis`。
- Windows 管理策略：`Software\Policies\GCSA Aegis`。生成的策略模板与运行时使用同一路径；macOS 策略模板沿用实际 Bundle ID `app.gcsa.aegis`。

## 服务身份

| 用途 | 固定 GUID |
| --- | --- |
| Active Setup | `43A39D18-33E1-5306-B967-2CE20EC76C03` |
| 通知激活 | `FF8EF761-F35A-5216-AB8D-6AC4DD060FA6` |
| 提权服务类 | `1A5BB399-46A8-5B7C-A32F-89533013FB7C` |
| 提权接口及类型库注册 | `BB19A0E5-3C2F-5D8D-A376-B9EFFDD77FFE` |
| 跟踪服务类 | `7EF1162A-E1E3-53B9-ADFD-C3F61A33CFC4` |
| 跟踪接口及类型库注册 | `E0B03E2D-A44C-5C6A-A66A-13B39AF883E5` |

沙箱也使用独立 SID 前缀，保留原有隔离规则。Aegis 不注销原版 Chromium 的历史跟踪接口。接口 UUID 通过 Chromium 自带的 MIDL 映射同步到头文件、代理与类型库；保留首字段顺序，继续执行代理桩一致性检查。

070 是旧的 Windows 构建基线，其 Chromium 目录与注册不能直接视为 Aegis 升级对象。本批不自动迁移、覆盖或删除 Chromium 资料。测试包、正常产品安装和已有 Chromium 必须分别核对。

## 验证边界

显示名变更会改变含品牌名的 GRIT 文案 ID。更新品牌时须同时迁移已有中文翻译，保留简体中文、香港繁体和台湾繁体的密码导入、导出标题。以下回归使用已应用补丁的 Chromium 源码及其 GRIT，生成并读回四种语言的密码对话框 `.pak`，可检测 ID 不匹配造成的英文回退：

```bash
python3 apps/browser/scripts/grit-password-locales_test.py \
  /path/to/chromium/src /path/to/test-output/password-locales
```

该回归验证资源生成和译文查找。实际 Windows 包仍需执行 `windows-uninstall-locales_test.py` 及原生界面验收。

已通过策略源码生成器 14 项测试、策略模板 185 项测试，以及 x86/x64/ARM64 六组 MIDL 输出映射检查。这些结果不能替代 Windows 原生编译、安装、通知、服务权限和与 Chromium 共存验收；后者须在实际 Windows 包完成后执行。
