# iOS 内部测试节点支持 VLESS WebSocket/TLS

普通 DEV 和内部 Alpha 通过现有 Options 的文本或扫码入口导入一条 VLESS 分享。预览只显示协议，Apply 后沿用本 Profile 的本机 Keychain、监听端点与代次撤销。原 TCP/REALITY/Vision 格式仍可用。

WebSocket/TLS 连接由已锁定的内嵌 Xray 执行。客户端使用链接指定的上游地址、DNS 服务名称、WebSocket Host 和路径，使用设备信任库校验证书和 TLS 服务名称。支持空 ALPN 或 HTTP/1.1。保留 HTTP Host 的显式端口，拒绝路径中的 Xray early-data 参数。只生成一个 VLESS 出站，不接受透传配置、明文模式或跳过校验。本地 HTTP CONNECT／已准入 SOCKS5 入口沿用现有行为。签入订阅、账户托管出站以及 Beta / Release 的原生门禁维持现有合同。

上游域名使用 DNS 的 ASCII 表示。TLS 服务名称使用无需尾点的 ASCII DNS 名，独立的 HTTP Host 可保留 DNS 尾点和端口。路径保留输入中的请求字节，允许 HTTP/HTTPS 回调地址，并拒绝混入另一条代理分享。

Keychain 继续读取 REALITY v1 与 WebSocket/TLS v2 记录。Options 应用节点时写入带协议种类的 v3 记录，读取旧记录时保留原版本。降级到只认识 v1 或 v2 的构建前，先在新版 Options 显式删除已保存的 v3 测试节点。
