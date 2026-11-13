# iOS Access：feat 拆分与并发

日期：2026-11-08（Asia/Shanghai）  
范围：先 iOS；本机入站仅 HTTP/HTTPS；出站必需 `reality_vision`；SOCKS5 / WS+TLS 本批不可构造。  
提交纪律：一 feat 一 PR；分支 `feat/ios-access-<slug>-2cd7`；标题与正文不出现自动化工具品牌字样。

## 冻结合同（F1）

| 项 | 取值 |
| --- | --- |
| 入站 | `http=1`，`https=2`；`socks5=3` 保留且 fail closed |
| 出站 | 仅 `reality_vision`；`ws_tls_compat` 保留且 fail closed |
| 监听 | 仅 loopback；凭据只发给已登记 registration |
| HTTPS 入站 | 本机 TLS 壳，不是站点中间人 |
| 运行时 | 不使用 Network Extension；不做系统 VPN |
| 源码 | `apps/ios/AccessKit` |

## 14 个 feat

| ID | 标题焦点 | 轨道 |
| --- | --- | --- |
| F1 | freeze transport and owner contracts | 合同 |
| F2 | registration and lease types | 合同 / 入站前置 |
| F3 | loopback HTTP inbound listener | 入站 |
| F4 | HTTP CONNECT on inbound | 入站 |
| F5 | HTTPS inbound TLS front | 入站 |
| F6 | pin fixed Xray asset digests | REALITY |
| F7 | generate reality_vision outbound config | REALITY |
| F8 | embedded Xray runtime lifecycle | REALITY |
| F9 | apply ProxyConfiguration to data store | WebKit |
| F10 | probe reality path with controlled node | REALITY |
| F11 | HTTP inbound to reality path | 汇合 |
| F12 | HTTPS inbound to reality path | 汇合 |
| F13 | isolate private browsing access state | 产品 |
| F14 | simulator evidence and feature catalog notes | 证据 |

## 并发模型

F1 合入后最大并行 3 轨：

1. 入站：F2 → F3 → F4 → F5  
2. REALITY：F6 → F7 → F8 → F10（无受控节点时 F10=`BLOCKED_RESOURCE`）  
3. WebKit：F9（可用假 registration fixture）

另设：

- 串行 review：一次只审一个 feat PR  
- 调度：放行闸门、合入顺序、上游晋升切片  

硬汇合：F11 需要 F4 + F8 + F9 + F10。禁止把入站、出站、WebKit 或本地化/Firebase/云签名混进同一 PR。

## 明确不做

SOCKS5 可构造路径、WS+TLS 主出站、Network Extension、用直连 origin 冒充 REALITY、真机/TestFlight 发行门（F14 记 `NOT_RUN`）。
