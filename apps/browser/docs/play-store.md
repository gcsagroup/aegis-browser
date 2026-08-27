# Play Store 预留（未上架）

侧载先发。下面是上架前必须对齐的身份，避免以后改 applicationId。

| 项 | 值 |
|---|---|
| applicationId | `app.gcsa.aegis` |
| 显示名 | GCSA-aegis |
| 短名 | Aegis |
| 默认语言 | 中文（简体） |
| 架构 | arm64-v8a（`target_cpu = "arm64"`） |
| 签名 | Play App Signing；本地只保留 **upload key** |

## 不能用的品牌

不要写 Chrome、Google Chrome，不要用 Chromium 默认图标上架。侧载阶段显示名已改成 GCSA-aegis；上架前替换 `chrome/android/java/res_chromium_base/mipmap-*` 图标。

## Data safety（按当前产品填）

- 不收集账号、位置、通讯录
- 页面摘要默认不出机器
- 无第三方分析 SDK
- EasyList 更新是用户设备拉过滤列表，不是把浏览记录上传

## 上架清单

1. Play Console 应用（包名 `app.gcsa.aegis`，建完不能改）
2. `AEGIS_PLAY_STORE_PASS=… bash apps/browser/scripts/android-keystore.sh`（密钥不入库）
3. 隐私政策 URL（本地优先、无遥测）
4. 截图：`chrome://aegis`、钓鱼拦截页、跟踪拦截
5. 内容分级、目标受众
6. 内部测试轨先发，再开放测试

GN 里已经写了 `chrome_public_manifest_package = "app.gcsa.aegis"`（`args/aegis-android.gn`）。
