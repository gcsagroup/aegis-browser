# Android 真机 UI 验收工具

这是 USB 连接下的一次性测试工具，不是浏览器功能、模型执行器或发行产物。它用于真实中文输入、按已观察到的节点点击和读取界面结果，避免将 `adb input text` 的字符丢失误判成 Agent 故障。

## 边界

- 包名固定为 `app.gcsa.aegis.qa.driver`。没有网络权限、启动器入口、常驻服务或常驻无障碍授权；只通过 Android instrumentation 运行。使用不抑制用户现有无障碍服务的选项。
- `self-test` 仅在自己的夹具 Activity 输入合成中文、点击并读取结果。不操作浏览器，不算 Agent 通过。
- 浏览器操作前核对本次成功构建、源码清单、实际 APK 哈希、Android 用户、亮屏解锁状态和唯一独立 Profile。设备端还会再次检查 APK 与已打开的 Profile 文件路径，不读取浏览数据库正文。
- 只允许快照、点击和文本输入。不支持任意 shell、坐标点击、系统授权、密码框、其他应用或自动解锁。点击/输入需要 60 秒内同一候选的快照；设备端在操作前再次比较界面摘要，变化即停止，不盲目重试。
- 快照有节点数量、深度、字符串和总大小限制。密码节点不返回原值。此工具只能用于获准的公开只读站点和合成夹具，不能向文本参数传入密钥或其他真实敏感数据。
- 构建使用仓库外私有临时签名密钥，签名后移除密钥。不会使用产品签名密钥。已有同名工具必须与指定 APK 哈希相同，否则拒绝覆盖或卸载；工具更新需要先明确核验旧安装的归属。

## 使用

在集成工作区根目录运行。SDK 需要 Android 36 和 build-tools 36.1.0；JDK 路径显式指定。

```sh
node apps/browser/scripts/android-agent-ui.mjs build \
  --sdk /Users/lazy/Library/Android/sdk \
  --jdk /opt/homebrew/Cellar/openjdk/25.0.2/libexec/openjdk.jdk/Contents/Home \
  --output /绝对路径/新的工具构建目录

node apps/browser/scripts/android-agent-ui.mjs self-test \
  --adb /Users/lazy/Library/Android/sdk/platform-tools/adb \
  --serial 48311FDKD002P8 \
  --driver-build /绝对路径/工具构建目录 \
  --output /绝对路径/新的自测结果.json
```

`self-test` 会安装设备上尚不存在的测试工具，完成后关闭自己的夹具 Activity，保留工具 APK 及自测证据。浏览器新包必须另外完成安装和独立 Profile 启动，本工具不会自动完成这两项。

```sh
node apps/browser/scripts/android-agent-ui.mjs snapshot \
  --adb /Users/lazy/Library/Android/sdk/platform-tools/adb \
  --serial 48311FDKD002P8 \
  --driver-build /绝对路径/工具构建目录 \
  --profile /data/user/0/app.gcsa.aegis/aegis-test-user-data-recovery-r1 \
  --source-root /Users/lazy/Projects/GCSA-aegis-chromium-linux-amd64/src \
  --manifest /绝对路径/候选清单.json \
  --build-dir /绝对路径/候选构建记录目录 \
  --output /绝对路径/新的界面快照.json
```

点击时将 `snapshot` 换成 `click`，保留相同候选参数，并添加 `--snapshot` 和快照中实际存在的 `--node`。中文输入使用 `set-text`，再添加 `--text`。每次操作后重新检查返回的真实界面；`actionAccepted` 仅表示系统接受输入，不表示页面目标、模型任务或定时任务成功。

## 已验证与未验证

2026-09-06，Pixel 9 Pro Fold `48311FDKD002P8` 的工具自测通过：中文及 emoji 输入、点击后的完整回显、过期快照拒绝、错误应用拒绝、密码框拒绝、密码内容隐藏，共 6 项。宿主单元测试 13 项通过，已加入 `pnpm quality:fast`。

真实设备上的浏览器原生前置检查拒绝了默认 `app_chrome` Profile；拒绝发生在读取浏览器界面之前。最新浏览器 APK 尚未完成，因此尚未把此驱动用于最新浏览器任务，也不将工具自测等同于 WebUI 可操作或 Qwen 端到端通过。

Android 公共 API 依据：[UiAutomation](https://developer.android.com/reference/android/app/UiAutomation)、[文本设置操作](https://developer.android.com/reference/android/view/accessibility/AccessibilityNodeInfo.AccessibilityAction#ACTION_SET_TEXT)。
