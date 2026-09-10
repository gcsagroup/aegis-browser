# 模型选择本地修复验收

结论：模型选择已修复，已在 macOS 真实侧栏完成展开、切换、保存及重启验证。不是整版或跨平台发布验收。

## 原因与修改

本地 `http://127.0.0.1:8000/v1/models` 实际返回五个模型。旧侧栏使用带 `datalist` 的输入框，点击箭头、清空名称后按下方向键均未展开候选；本次复现不等于已定位 Chromium 自动填充内部的具体缺失点。

将候选改为独立原生 `select`，保留手动输入。选择时同步完整模型名，输入时同步候选状态；更改服务、接口格式或密钥后清除旧列表。检测失败或异常时恢复按钮，不保留旧候选。手动输入的名称不因重新检测而被覆盖。

## 验证

- `pnpm --filter @gcsa-aegis/browser test:agent-ui`：原有74项、新增11项通过，另含HTML结构检查。这些是代码测试，不冒充实机结果。
- Chromium正式资源构建目标 `packed_resources_extra__repack`：成功，包含 TypeScript 编译、lint、资源生成与打包。
- 对照R19冻结源码，验收源码仅 `agent.html`、`agent.ts` 两项变化；原生C++源码保持基线。
- 对比旧包与新资源包全部资源键和值：键集合相同，仅资源23852、23853变化。
- 实际侧栏菜单展开五个完整模型名；选中 `Qwen3.8-27B-direct-A-best15-MLX-4bit` 后输入框同步，保存后状态显示该模型。
- 正常退出，再启动同一签名包，侧栏仍显示已保存的Qwen3.8；独立资料的 `aegis.model_name` 与之匹配。
- 再次通过菜单切回并保存原有 `Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit`。
- `codesign --verify --deep --strict` 通过。未读取私钥内容、保存系统密码或改变钥匙串访问控制。

## 固定入口与恢复

- App：`/Users/lazy/Applications/GCSA Aegis Test.app`
- 独立资料：`/Users/lazy/Library/Application Support/GCSA Aegis Acceptance`
- 使用用户已同意的 `Apple Development: lazy@lolrz.com`，身份指纹 `2CECC81C4E125A9C25CCA52AE002FCEBC7616B91`。
- 测试副本的 `CrProductDirName` 固定为 `GCSA Aegis Acceptance`，直接启动也使用独立资料，不依赖每次传入命令行参数。
- 旧R19包及原资料完整保留在 `.artifacts/v2-final/macos-page-evidence-ui-r19/`。资料在旧进程正常退出后复制，不删除旧数据。
- 退出检查曾使旧包自动启动一次无参数空白窗口，已立即正常退出；之后只重启固定包。未手动修改该空白窗口的浏览资料。

## 证据边界

首次尝试包含提示文案的整包构建，链接因系统文件句柄耗尽失败。没有调整系统限制。随后撤回本次新增的C++文案，使用现有本地化文字，正式重建界面资源并验证只改变两项资源。交付包以保留的R19程序为基底更新资源、设置独立资料路径并重新签名，不声称本次全量链接成功。

本次没有运行模型推理或评价五个返回模型各自的工具调用能力；服务列出模型、选择与保存成功，不代表每个模型都适合浏览器任务。没有提交、推送、部署、App Store发布或公证。
