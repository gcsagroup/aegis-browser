# Research → module map

| Paper | arXiv / venue | Product module | How we use it |
|-------|---------------|----------------|---------------|
| Big Help or Big Brother? | [2503.16586](https://arxiv.org/abs/2503.16586) | Privacy AI | Competitive narrative: local-first vs cloud browser assistants |
| WebLLM | [2412.15803](https://arxiv.org/abs/2412.15803) | model-runtime | In-browser local inference backend |
| Client-side URL analysis | [2506.03656](https://arxiv.org/abs/2506.03656) | Privacy AI / Phish | Local zero-shot page/URL analysis pattern |
| PhishLang | [2408.05667](https://arxiv.org/abs/2408.05667) | Phish | Client-side LM phishing; we ship heuristics first, model slot next |
| Explain, Don't Just Warn! | [2505.06836](https://arxiv.org/abs/2505.06836) | Phish | Explainable block page UX |
| EXPLICATE | [2503.20796](https://arxiv.org/abs/2503.20796) | Phish | XAI-style reason codes |
| WebGraph | [2107.11309](https://arxiv.org/abs/2107.11309) | Tracker | Action/flow features for future classifier |
| PURL | [2308.03417](https://arxiv.org/abs/2308.03417) | Tracker | Link decoration sanitization |
| ASTrack | [2301.10895](https://arxiv.org/abs/2301.10895) | Tracker | Fine-grained tracking removal inspiration |
| AdGraph | [1805.09155](https://arxiv.org/abs/1805.09155) | Tracker | Graph ML lineage |
| First-party / SST tracking | [2606.16720](https://arxiv.org/abs/2606.16720) | Tracker | Heuristics beyond third-party lists |
| MV3 ad blocker study | [2503.01000](https://arxiv.org/abs/2503.01000) | Tracker | DNR-first architecture validation |
| CookieBlock | USENIX Sec'22 | Tracker | Cookie purpose classification + enforcement |
| CookieGraph | [2208.12370](https://arxiv.org/abs/2208.12370) | Tracker | First-party tracking cookies (inspiration; no graph ML) |
| SST-Guard | [2604.27497](https://arxiv.org/abs/2604.27497) | Tracker | sGA path/query artifacts beyond EasyList |
| Casper | [2408.07004](https://arxiv.org/abs/2408.07004) | Privacy AI | Show on-device PII redaction to the user |
| ByteDefender | [2509.09950](https://arxiv.org/abs/2509.09950) | Browser fork | Function-level fingerprint detection (future) |
| MINIM | [2606.13949](https://arxiv.org/abs/2606.13949) | AI 控制 / CDP | 借鉴「观察最小化」：默认关闭远程调试；开启后仅 loopback CDP；远程 target 列表不暴露 chrome:// / file://；连接数写入会话清单，连上后浏览器顶部出现横幅。不复现完整训练/云浏览器方案 |
| FP-Fed | [2311.16940](https://arxiv.org/abs/2311.16940) | Browser fork | Federated fingerprint script detection (future) |
| WebGPU privacy | [2606.26412](https://arxiv.org/abs/2606.26412) | Browser fork | adapter.info 字符串 + 若干 limits（maxBufferSize 等）按站点向下收档。不是「无法指纹」 |
