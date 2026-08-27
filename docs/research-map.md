# Research-to-implementation map

**English** | [简体中文](research-map.zh-CN.md) | [繁體中文](research-map.zh-TW.md)

This document separates implemented engineering, research inspiration, and missing evidence. Citing a paper does not mean that GCSA-aegis reproduced its model, dataset, accuracy, privacy, or security conclusions. The current product is an integrated Chromium browser; extension research is retained only as historical context.

## Phishing, URLs, and explanations

- [Client-side URL analysis](https://arxiv.org/abs/2506.03656): the browser has bounded URL and page heuristics. Dynamic JavaScript analysis does not run on the normal navigation hot path.
- [PhishLang](https://arxiv.org/abs/2408.05667): the implementation includes punycode and selected brand, path, credential, and cross-site form signals. It does not include the paper's dual-input language model.
- [Explain, Don’t Just Warn!](https://arxiv.org/abs/2505.06836): phishing interstitials expose reason codes and weights. User-comprehension testing and broader localization evidence remain open.
- [EXPLICATE](https://arxiv.org/abs/2503.20796): deterministic reason codes improve traceability, but they are not a reproduction of a complete explainable-AI system.

Current direction: keep deterministic high-confidence checks in the browser, reserve any future model for bounded ambiguous cases, and validate false positives on independently labeled data before changing blocking behavior.

## Tracking, cookies, and link sanitization

- [WebGraph](https://arxiv.org/abs/2107.11309): Core has a bounded behavior-graph aggregation function over caller-supplied events. Chromium does not yet collect the complete DOM, storage, identifier, redirect, and network flow required for a browser WebGraph system.
- [PURL](https://arxiv.org/abs/2308.03417): runtime code uses a fixed tracking-parameter set. Site-level rules should be generated offline and accepted only after compatibility regression.
- [ASTrack](https://arxiv.org/abs/2301.10895): a Node-only AST structure-signature prototype can identify multi-site candidates. It does not implement branch-safety analysis, semantic slicing, code rewriting, or selective deletion.
- [AdGraph](https://arxiv.org/abs/1805.09155): no production graph classifier is implemented.
- [First-party and SST tracking](https://arxiv.org/abs/2606.16720) and [SST-Guard](https://arxiv.org/abs/2604.27497): current coverage is limited to selected collection paths and parameter patterns, not all server-side tagging.
- [MV3 ad-blocker study](https://arxiv.org/abs/2503.01000): relevant to the historical extension phase, not proof for the current Browser-only architecture.
- [CookieBlock](https://www.usenix.org/conference/usenixsecurity22/presentation/bollinger): current cookie handling is rule- and name-based and still requires representative sign-in and payment regression.
- [CookieGraph](https://arxiv.org/abs/2208.12370): a complete cookie information-flow graph is not implemented.
- [The CNAME of the Game](https://petsymposium.org/popets/2021/popets-2021-0053.pdf): the browser checks network-provided DNS aliases against local tracker rules; this is not a general CNAME-tracker classifier.

## Privacy AI, minimization, and local automation

- [Big Help or Big Brother?](https://arxiv.org/abs/2503.16586): desktop summary supports an on-device heuristic and a user-configured compatible API. Remote use sends bounded redacted text only after destination confirmation, but full Chromium egress proof is still missing.
- [WebLLM](https://arxiv.org/abs/2412.15803): a research-only local advisory contract accepts de-identified feature categories and must abstain on errors. No in-browser WebLLM backend or bundled model exists.
- [Casper](https://arxiv.org/abs/2408.07004): current redaction uses deterministic patterns and checksums. Broader on-device NER remains future work.
- [MINIM](https://arxiv.org/abs/2606.13949): selected CDP paths narrow exposure through provenance and exact-document authorization. An authorized local agent can still read the raw DOM of authorized HTTP(S) pages.

## Fingerprinting and JavaScript research

- [ByteDefender](https://arxiv.org/abs/2509.09950): a default-off V8 Ignition opcode-shadow prototype emits bounded observe-only summaries. It has no function-level model or blocking and does not cover every cache, snapshot, or Wasm path.
- [FP-Fed](https://arxiv.org/abs/2311.16940): a local simulation explores clipped updates, pairwise masking, and Gaussian noise. It is fixed as non-deployable and is not real secure aggregation or an opt-in production system.
- [WebGPU privacy](https://arxiv.org/abs/2606.26412): selected adapter strings, limit buckets, and high-entropy subgroup signals are reduced. Active-output, timing, and pipeline-cache channels remain open research.

## Current JavaScript and MinerGuard boundary

- The Node-only AST analyzer uses the TypeScript parser, applies size and complexity limits, and emits counts and reason codes without source text, literals, URLs, or payloads. It is not in the page execution path.
- Bounded behavior and provenance functions operate only on caller-supplied, categorized events. They are not a live browser information-flow system.
- MinerGuard combines selected browser-side CPU estimates, Worker/Wasm/WebGPU/shared-memory signals, WebSocket observations, and strong endpoint tokens. It records observe-only findings and does not stop scripts, workers, or connections.
- The current research corpus consists of synthetic fixtures. Its content digest checks integrity, not independent sealing; `sealIsolationVerified=false`, `finalEvaluationEligible=false`, and the final-evaluation path remains locked.

## Evidence and release gates

1. Keep research metrics separate from product runtime and release qualification.
2. Require independent benign and malicious labeling, real-site coverage, obfuscation tests, false-positive measurement, performance budgets, and breakage testing before a detector can affect page behavior.
3. Do not describe an observe-only signal, synthetic-fixture result, or claims-completeness check as a security authorization.
4. Re-run affected gates against the same committed source and identity-bound artifact. The live source has 56 top-level Chromium patches plus 2 nested V8 patches, while the latest identity-bound build-tree covers only 54 plus 2.

The research program remains **No-Go for production blocking and general malicious-JavaScript claims**.
