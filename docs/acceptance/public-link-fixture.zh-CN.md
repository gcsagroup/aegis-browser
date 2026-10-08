# 独立公网链接夹具

此服务只提供合成状态码，用于 500 条链接检查中的 450 条 HTTP 地址；另 50 条 file 地址保持范围拒绝负例。它不读取浏览器资料、不访问任意外部地址，也不提供模型、控制或证据接口。默认仅监听回环地址。

```sh
node apps/browser/scripts/public-link-fixture.mjs --host 127.0.0.1 --port 49211
```

部署主机需要 Node.js 20 或更新版本。将受控 HTTPS 域名反向代理到此进程；保留状态码、Location、Retry-After，关闭缓存，并将代理响应超时设为大于 12 秒。不要代理 `verify-agent-runtime.mjs` 的完整开发服务。只有部署网络确实需要时才显式指定 `--host 0.0.0.0`，并按既有部署边界限制访问。

| 路径 | 服务行为 |
| --- | --- |
| `/healthz` | 200，正文 `aegis-link-fixture-v2` |
| `/status/live` | GET/HEAD 200 |
| `/status/head-unsupported` | HEAD 405，GET 200 |
| `/status/redirect` | 302 到同源 `/status/live` |
| `/status/auth`、`/status/rate` | 403、429 |
| `/status/gone`、`/status/missing` | 410、404 |
| `/status/temporary` | 503 |
| `/status/timeout` | 12 秒后返回 200；浏览器必须先触发自己的超时，才能验证超时分类 |
| 其他路径／非 GET、HEAD 方法 | 404／405 |

取得域名后重新导出具名准备包，不修改旧包：

```sh
node apps/browser/scripts/verify-agent-runtime.mjs \
  --export-readiness /绝对路径/新准备包 \
  --public-origin https://实际受控测试域名
```

先从实际验收设备核对 DNS、证书、状态码、HEAD 回退、重定向和延迟，再进入浏览器任务批次。进程启动及 HTTP 自测不会将 `publicDeploymentVerified`、`browserExecuted` 或 `agentExecuted` 改为 true。浏览器结果仍须来自原生回读，不得直接复制夹具预期。

退出服务使用 Ctrl-C 或向本次进程发送 SIGTERM；服务会关闭连接并取消未完成的延迟响应。不创建容器，不修改已有开发服务器。
