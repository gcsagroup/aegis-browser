# iOS Delivery Actions operator guide / iOS 交付操作指南

In the upstream `gcsagroup/aegis-browser` repository, open **Actions**, select **iOS Delivery · Simple** or **iOS Delivery · Full**, choose **Run workflow**, and select the `main` branch. The original operator and any rerunner must have effective repository Admin access.

在上游仓库 `gcsagroup/aegis-browser` 打开 **Actions**，选择 **iOS Delivery · Simple** 或 **iOS Delivery · Full**，点击 **Run workflow** 并选择 `main` 分支。首次发起与重新运行均要求实际的仓库 Admin 权限。

## Signing mode / 签名模式

New packages default to **cloud** in both forms, the CLI, Fastlane and candidate
tags. Use **manual** explicitly for the existing certificate/profile fallback:
Actions **Signing mode → manual**, CLI `--signing-mode manual`, Fastlane
`signing_mode:manual`. Cloud packaging uses the admitted macOS runners configured
in the workflow without importing a Distribution P12. Cloud failure stops the attempt;
manual is an operator selection, with a new run ID and an unused build.

两个表单、CLI、Fastlane 和 candidate tag 的新包均默认 **cloud**。显式回退选择：Actions 的 **Signing mode → manual**、CLI 的 `--signing-mode manual`、Fastlane 的 `signing_mode:manual`。cloud 使用工作流指定且通过准入的 macOS runner，不导入分发 P12；失败后停止，由操作者核对状态并选择 manual、未占用 build 与新 run ID。

Signing mode applies only to **Package**, **Package and upload**, and **Draft**.
Leave it at the default for **Status**, **Wait** and existing-package stages;
those routes use the retained package evidence. Lightweight and ordinary
annotated tags select cloud; see the [explicit manual tag format](ios-cloud-signing-poc.md#current-signing-default-and-manual-fallback).

签名模式仅作用于 **Package**、**Package and upload** 和 **Draft**。**Status**、**Wait** 及已有包阶段可保持默认，按保留的包身份和签名证据处理。轻量或普通注释 tag 默认 cloud；显式 manual tag 格式见上述指南。

## Simple / 日常操作

Enter **Version** and **Build** separately. For a new package, choose **Product**. **Alpha** is internal-only, **Beta** supports internal and external testing, and **Release** supports release destinations through explicit stages.

分别填写 **Version**（如 `1.0.0`）和 **Build**（如 `35`）。打包时选择 **Product**。**Alpha** 仅供内测，**Beta** 支持内测和外测，**Release** 可通过独立阶段用于发布。

| Operation | English | 中文 |
| --- | --- | --- |
| **Status** (default) | Query the exact version and build in TestFlight. Leave **Product** at its default. | 查询指定版本和构建号的 TestFlight 状态，**Product** 保持默认。 |
| **Wait** | Wait up to 30 minutes for processing. Leave **Product** at its default. | 等待处理，最多 30 分钟，**Product** 保持默认。 |
| **Package** | Produce an IPA, dSYM and manifest for an unused build number. | 使用未占用的构建号，生成 IPA、dSYM 和清单。 |
| **Package and upload** | Check availability, package once and upload that IPA to TestFlight. Check **Status** before retrying after an uncertain result. | 检查构建号是否可用，打包后将同一份 IPA 上传至 TestFlight。结果不明时，先用 **Status** 核对状态。 |

**Status** and receipt-free **Wait** use only the exact version and build. Both are read-only.

**Status** 和不使用凭据的 **Wait** 均为只读查询，只需填写准确的版本和构建号。

For an authorized internal test-node Beta, select **Beta**, **manual**, **Package and upload**
and **private_beta → yes**. The signing environment supplies the private node and subscription
descriptor. Before uploading, the exported IPA must contain the exact validated resources,
and its HTTPS quota endpoint must return the matching client, expected allowance, enabled
state, unexpired access and positive remaining traffic. Redirects and invalid responses stop
delivery. Private inputs and the IPA are not published as Actions artifacts.

已授权的内置测试节点 Beta 使用 **Beta / manual / Package and upload / private_beta → yes**。
节点及额度描述由签名环境注入。上传前核对 IPA 内资源与输入完全一致，并通过包内 HTTPS
入口验证客户端身份、额度、启用状态、有效期和剩余流量。重定向或无效响应会停止交付；
私密配置及 IPA 不作为 Actions artifact 公开。

If **Wait** times out, the run fails and retains the last observed Apple state in its Summary and status artifact. Use **Status** or **Wait** again to check that same build; do not upload it again.

**Wait** 超时仍会失败，并在 Summary 和状态 artifact 中保留最后一次 Apple 状态。使用 **Status** 或 **Wait** 再次查询同一构建，不要重新上传。

### Private TestFlight Alpha / Alpha 私有测试包

Use **Simple → Package and upload → Alpha → manual → private_alpha: yes** on
the current upstream `main`, with a fresh version/build allocation. The
`private-alpha-package` job requires the usual unused-build check and exact-source
admission. The tag, Full, Bot, cloud-archive, ordinary package, and GitHub Draft
routes do not support private Alpha. A standard Alpha build still omits the list.

Packaging uses `aegis-ios-signing` and `private-alpha-store` uses `aegis-ios-store`
for upload. Keep both environments' approval and branch protections. Configure
`AEGIS_IOS_PRIVATE_ALPHA_RUNNER_GROUP` and `AEGIS_IOS_PRIVATE_ALPHA_RUNNER_LABEL`
as upstream repository variables. The group must restrict access to
`gcsagroup/aegis-browser/.github/workflows/ios-delivery.yml@refs/heads/main`.
Admission requires a named group other than `Default` and distinct custom labels
for the private runner and the shared `AEGIS_IOS_RUNNER_LABEL`.
Assign the label to exactly one ARM64 macOS runner in that group, using an OS
account dedicated to this workflow and separate from PR validation. Keep its
temporary storage on SSD with room for DerivedData and export. The read-only
unused-build check uses `aegis-ios-store` and skips its Actions artifact for
private Alpha.

These inputs belong only in `aegis-ios-signing` as Environment secrets,
with no repository or organization fallback. Do
not put their values in a dispatch field, variable, repo file, or receipt:

- `AEGIS_IOS_ALPHA_NODES_BASE64`: one-line base64 for an ordered UTF-8 JSON
  array of supported node share strings. The format admits 1–16 distinct
  entries, each at most 8,192 UTF-8 bytes, with a canonical JSON size of at most 131,500 bytes. It accepts
  the four VLESS combinations, VMess over WebSocket or HTTPUpgrade with TLS,
  Trojan over TCP/TLS, and Hysteria2 over QUIC/TLS. Duplicate query
  keys, ambiguous aliases and unsupported options fail the build. Each URI
  must have the same client UUID as the anchored node. For password-based routes,
  the test password must be that account UUID. The live subscription must still
  advertise each route with its exact password. VMess with an explicit none or
  zero cipher and Hysteria2 with disabled TLS verification are rejected. Use compact
  JSON: [GitHub limits each secret to 48 KB](https://docs.github.com/en/actions/reference/security/secrets#limits-for-secrets).
- `AEGIS_IOS_TEST_NODE_BASE64`: base64 for the existing anchored TCP/REALITY
  VLESS URI used by the shared quota session.
- `AEGIS_IOS_TEST_SUBSCRIPTION_BASE64`: base64 for the existing quota
  descriptor for that same client. The product validator binds it to the
  anchored node's SHA-256 and the live quota check must confirm the configured
  identity, active allowance and remaining traffic.

#### Where the two lists live

The domestic and overseas GeoSite resources in Git describe which sites are
eligible for a route. They are public policy data. The private Alpha's VLESS
list contains credentials that authorize traffic on the operator's relay.
The upstream signing environment owns that list. A GeoSite policy refresh
can change site matching. Rotating relay credentials requires a new internal
Alpha build.

The private signing job materializes the validated list and subscription in
the signed app. Anyone holding that IPA can extract its resources. Limit the
build to internal testers and use a revocable test account with a bounded
allowance. The app stores the selected ordinal and catalogue fingerprint in
preferences. A catalogue change resets selection to its first entry, so keep
the order stable when refreshing an existing list.

When rotating the test account, prepare the list, anchor and quota descriptor
together. Confirm the live subscription advertises every intended route and
has remaining traffic. Set the three environment secrets between delivery
runs and validate the signed package before distribution. To revoke a
distributed credential, disable it at the subscription service and relay.
Changing an Actions secret affects subsequent builds.

The authenticated subscription response must advertise every intended route
with matching parsed node parameters. Serve the list
as plain text or base64 from the same HTTPS origin and path as the signed
quota descriptor, with the `format=info` query removed. A matching UUID alone
is insufficient. The app checks the subscription on refresh. Verifying real
traffic counts per route requires a device test.

The signing job verifies the exported IPA has one main-app copy of each of
`AegisAlphaTestNodes.json`, `AegisPrivateTestNode.vless` and
`AegisPrivateTestSubscription.json`, byte for byte, and has the internal-only
TestFlight marker. After removing the signing material, the job retains the
IPA, its manifest and checksum, and the three verification inputs in the
runner account's owner-only `~/.local/share/aegis-private-alpha` directory.
The handoff binds the repository, run, first attempt, runner name, source
commit and tree, and manifest digest. The store job rechecks those bindings,
the exact IPA and live quota before its upload step receives ASC credentials.
Private Alpha publishes zero Actions artifacts.

The signing job removes the build workspace under `RUNNER_TEMP`. The store
job uses the exact-source checkout to clean up its own handoff, including
after a failed preflight or upload. If the store job never reaches checkout
or its runner is lost, the runner operator must reconcile the run and remove
its retained copy and any remaining temporary files. Permanent upload
records contain only package identity.

Do not rerun a private Alpha upload. If upload started but did not return a
confirmed result, reconcile the exact version/build in App Store Connect
before attempting another delivery. An accepted upload does not confirm Apple
processing or device acceptance; use the existing Status or Wait route for
processing.

首次交付请在上游 `main` 使用 **Simple / Package and upload / Alpha / manual /
private_alpha: yes**，并在 `aegis-ios-signing` 受保护环境配置三项密钥。
四个节点须与锚定节点使用同一客户端 UUID。订阅响应须从已签名额度描述中的相同
HTTPS 源和路径提供明文或 Base64 的四个节点，移除 `format=info` 查询参数。
应用刷新时校验四个节点解析后的参数，单独匹配 UUID 不足。四个节点的实际流量
计数仍须真机验证。

签名作业在同一受信任 runner 上保留仅当前用户可访问的交接目录。
`private-alpha-store` 通过 `aegis-ios-store` 审批，重新核对同一次运行的交接、
IPA 和实时额度后加载 ASC 凭据，直传内部 TestFlight。失败或中断后先核对同一版本
和构建号的 Apple 状态，不要直接重跑。

### Private TestFlight Beta / 私有测试包

For a Beta that embeds the shared test node and reads its 3X-UI quota, choose
**Package and upload**, **Beta**, **manual**, and **Private Beta: yes**. Store
`AEGIS_IOS_TEST_NODE_BASE64` and `AEGIS_IOS_TEST_SUBSCRIPTION_BASE64` in the
upstream `aegis-ios-signing` Environment. The signing job checks both resources
in the signed IPA, removes signing materials and retains an owner-only copy outside
the runner workspace. The separate `private-beta-store` job requires the protected
`aegis-ios-store` Environment and the same runner. It verifies the source, manifest,
IPA hashes and live quota again before uploading to TestFlight for internal testing.
Only that store job receives ASC upload credentials. Actions retains a redacted receipt. If the result is uncertain, query
**Status** with the original version and build before scheduling another attempt.

内置共享测试节点并查询 3X-UI 实际额度时，选择 **Package and upload**、**Beta**、
**manual** 和 **Private Beta: yes**。两项输入只存入上游的
`aegis-ios-signing` 环境。签名作业检查 IPA 中的两份资源，清除签名材料，将包保留在
runner 工作区之外的当前用户私有目录。独立的 `private-beta-store` 作业经过
`aegis-ios-store` 受保护环境，在同一 runner 上重新校验源码身份、清单、包哈希及实时
额度，随后加载 ASC 凭据并上传 TestFlight 内测。Actions 只保留脱敏回执。结果不明时
先用原版本和构建号执行 **Status** 查询。

The private handoff is bound to the repository, run, first attempt, runner, source
and manifest. It is removed after upload processing. If the store job never starts,
the owner-only copy remains for reconciliation. A cancelled restore cleans its
run-bound staging or restored workspace copy and retains that original copy. Cleanup
checks the directory identity recorded before copying and keeps its ownership marker
until the private copy is removed, including after an interrupted cleanup. It is not a public artifact or a
reusable upload token. Runner admission must explicitly allow `private-beta-store`.

私有交接绑定仓库、run、首次 attempt、runner、源码与清单，上传处理后清除。若商店
作业未能启动，私有副本保留用于核对，不作为公开工件或可复用上传令牌。runner 准入
须明确允许 `private-beta-store`。

## Full / 分阶段交付

**Full** includes the **Simple** operations and adds the following stages. **Auto** uses **Alpha** for new packages and the receipt's profile for existing packages.

**Full** 包含 **Simple** 的操作，并提供下列阶段。**Auto** 为新包选择 **Alpha**，为已有包沿用凭据记录的包型。

| Operation | English | 中文 |
| --- | --- | --- |
| **Draft** | Use **Version**, **Build** and **Product** that match an existing `candidate/ios/<version>-<profile>.<build>` tag on current `main`. Pushing the tag also triggers packaging and private Draft creation. | 填写与当前 `main` 上已有 `candidate/ios/<version>-<profile>.<build>` 标签匹配的 **Version**、**Build** 和 **Product**。推送该标签也会触发打包并创建私有草稿。 |
| **Upload** | Upload an existing signed package using its **Delivery receipt**. | 用 **Delivery receipt** 上传已有签名包。 |
| **Wait** with a receipt | Track processing using the package's pinned **Delivery receipt**. | 用 **Delivery receipt** 跟踪已有包的处理状态。 |
| **Metadata** or **Compliance** | Supply the **Delivery receipt** and the reviewed **Stage JSON**. | 填写 **Delivery receipt** 和已审核的 **Stage JSON**。 |
| **Distribute internal** or **Distribute external** | Supply the **Delivery receipt** and existing **Existing TestFlight groups**. External distribution requests Beta App Review and requires separate authorization. | 填写 **Delivery receipt** 和已有的 **Existing TestFlight groups**。外测分发会发起 Beta App Review，须另行授权。 |

For a new sealed package, successful **ios-package** and **seal-package** jobs establish the original package receipt even if a later job fails. Existing upload intents still require reconciliation. Legacy unsealed packages and later state receipts require their whole source run to succeed. Copy the complete **Delivery receipt**, leave **Product** on **Auto**, and leave **Version** and **Build** blank.

新封存包的 **ios-package** 和 **seal-package** 均成功后，可保留原包 **Delivery receipt**，后续作业失败时仍可核验原件。已有上传意图须先对账。旧未封存包和后续状态回执仍要求来源运行整体成功。复制完整回执，将 **Product** 保持为 **Auto**，留空 **Version** 和 **Build**。

For protected environment setup, stage JSON examples and recovery steps, see the [iOS release operations reference](ios-release.md).

受保护环境配置、阶段 JSON 示例及故障恢复步骤见 [iOS 发布操作参考](ios-release.zh-CN.md)。

## Product-owned archive, receipts and Downloads

Cloud packages use a Development-only archive job and a separate protected export job.
The settings job passes only validated team and Firebase variables from the existing
signing Environment. It checks out no product code. The archive job receives no ASC
secret and uses the existing Development identity and profiles.

Automatic archive signing uses Xcode-managed Development profiles. On a host with
dedicated manually created Development profiles, explicitly configure the owner-only
`~/.config/gcsa-aegis-signing/development-archive.json` (directory `0700`, file `0600`,
both owned by the runner account with no extended ACLs):

```json
{
  "schema": "aegis-development-signing-v1",
  "team": "YOURTEAMID",
  "certificateSha1": "UPPERCASE_SHA1_OF_DEVELOPMENT_CERTIFICATE",
  "profiles": {
    "com.gcsa.aegis": "APP_PROFILE_UUID",
    "com.gcsa.aegis.safari": "SAFARI_PROFILE_UUID",
    "com.gcsa.aegis.share": "SHARE_PROFILE_UUID"
  }
}
```

This file contains public identifiers only. The archive verifies Apple CMS trust,
Development entitlements, team, exact bundle IDs, certificate membership and expiry;
it then pins each target's profile and the Development identity. The archive transfer
records this selection and checks actual embedded profiles and signer fingerprints.
An invalid configured selection fails without falling back. With no configuration,
the existing automatic Development selection remains in use; existing path components
must be physical directories, including when a linked destination is missing. Lookup
compares full profile filenames without case assumptions, allows at most eight matching
copies across the approved directories, and rejects the first content conflict. The dedicated keychain
must be available to headless `codesign`. An optional owned `0600`
`development-keychain.password` companion in the same private configuration
directory enables activation in the actual runner session. The archive worker
finds the unique owned non-login keychain containing the pinned certificate,
rejects Distribution identities, and passes the password directly to
Security.framework. It never passes that password to a command or build phase.
Without the companion file, the existing pre-unlocked-keychain contract applies.
The dedicated Development keychain file must remain in the runner account's
`security list-keychains -d user` search list (alongside login). If only
`login.keychain-db` is listed, archive activation fails with
`Unique owned dedicated Development keychain required` even when the dedicated
database still exists under `~/Library/Keychains/`.

Before building the app, the isolated worker compiles a fixed trivial probe,
signs it with the configured Development identity and verifies the signature.
The probe's environment contains only public toolchain/home/temp settings.
Activation and probe diagnostics are retained separately from the archive;
`find-identity` success alone is not evidence that the private signing operation
works in a background runner. Direct inline Development archives use the same
preparation before isolation and the same probe inside it.

Private configuration ancestors must be owned by the runner account or root and
exclude directory mutation by other accounts, including extended ACL grants.
Writable ancestor ACL entries are accepted only when native membership lookup
identifies their principal as the runner account or root; groups and unknown principals fail closed.
Root/account-owned sticky temporary ancestors are allowed; the private signing
directory and configuration file still require their exact private modes and no ACLs.
Direct Fastlane/PoC inline Development archives apply the same explicit selection
and signed archive verification. The production transfer workflow provides the
separate archive/export jobs.

This selection changes only Development archive signing. Xcode 27.2's installed
`xcodebuild -help` explicitly supports a manually signed archive followed by automatic
distribution, including managed cloud signing certificates. Cloud export remains
`signingStyle=automatic` and imports no Distribution P12. Archive transfer v2 requires
the matching producer source and includes the Development signing evidence. The
producer job publishes the whole manifest SHA-256 separately as a job output; export
requires that pin and verifies the ZIP digest before permanently allocating the
export coordinate. The producer serializes the manifest once and binds its output
digest to those exact written bytes; import repeats the integrity checks. Relative
transfer paths are resolved once from the request repository root, and the verified
arguments pass to export without a second Ruby ZIP read.
Older source-bound transfers remain with their original implementation.

Successful package jobs are sealed independently of later upload results. Small
create-only records under `refs/heads/ios-delivery/` retain the Apple allocation,
original package job, artifact ID/digest and upload intent/result. A successful
package and seal can therefore supply the original receipt after a later job
fails. Downloaded original bytes and the exact producer are verified again.
Binary artifacts retain their 30-day limit. Missing originals or ambiguous records
require read-only reconciliation. Repository administrators retain their ability
to change Git refs. Local artifact-only manual packaging keeps its read-only
GitHub admission. New Apple uploads require Contents write for their permanent
intent, including uploads made by the local CLI.

Status and receipt-free Wait use independent read-only concurrency groups.
Signing, uploading, Draft creation and distribution share the existing mutation
queue.

Verified deliverables are also copied to
`~/Downloads/artifacts/aegis/VERSION/alpha`, `Beta`, `Release` or `Draft`.
Each filename includes its build number and content digest. Existing bytes are
checked before reuse, and different builds cannot overwrite one another.
`GCSA_DELIVERY_ROOT` overrides the catalogue root. A failed catalogue copy leaves
the verified source package available. Retry only the copy with:

```sh
python3 scripts/release/ios-publish.py --directory .artifacts/release/ios/RUN_ID --manifest-sha256 MANIFEST_SHA256
```

Use `--draft` for the Draft folder. The catalogue contains IPA, dSYM and delivery
evidence. On a self-hosted runner the default root belongs to that runner's user.
Use the same copy command on downloaded, verified original files for a local
catalogue.

## Routine execution without AI / 无 AI 日常执行

### Dedicated delivery App / 专用交付 Bot

The **iOS Delivery · Bot** controller reuses the existing Simple/Full engine. An
Admin starts it on current `main`, selecting the exact version/build, product and
operation. **Package and upload** monitors its exact producer run and then starts
read-only **Wait** for that same coordinate. **Draft** uses the existing Full route
and requires an administrator-created, source-matching candidate tag. The Bot
cannot create candidate tags, distribute to external testers, submit App Review
or publish a public GitHub Release.

Register a dedicated GitHub App with only repository **Actions: write**,
**Contents: read** and implicit **Metadata: read**. Install it on an explicitly
approved `gcsagroup` repository inventory after verifying the maintainer's actual
Admin or Owner grant for each repository. Personal account installations are
excluded. This iOS controller always limits each token to
`gcsagroup/aegis-browser`, regardless of the App's broader installation inventory.
Configure the repository variable
`AEGIS_IOS_DELIVERY_BOT` as
`{"appId":123,"slug":"your-delivery-app","actorId":456}` using the actual App ID
and numeric ID of its `your-delivery-app[bot]` user. The workflow independently
resolves those identities from GitHub; a matching display name is insufficient.
Set `AEGIS_IOS_BOT_INSTALLATION_ID` to that App's installation ID.

Create the protected `aegis-ios-bot` Environment with deployment restricted to
`main`; retain applicable approval requirements. Store the App's PEM private key
only as its Environment secret `AEGIS_IOS_BOT_PRIVATE_KEY`. Do not put Apple
credentials in that Environment. The controller requests a short-lived token
limited to the canonical repository and required permissions; the key is never
passed to delivery jobs. Signing and store jobs continue using their existing
environments and credentials.

The Bot's five permitted operations are **Package**, **Package and upload**,
**Draft**, **Status**, and **Wait**. External App clients must supply
`approved_source_sha` with the exact current main SHA to Simple/Full. Every
protected delivery job checks the Bot identity and that source again. Human
operators retain their existing Admin requirement. Coverage, validation, cleanup,
local CLI and candidate-tag pushes do not acquire Bot authorization.

The controller is never rerun to repeat mutations. Each successful dispatch is
immediately recorded in the log and Summary with its run ID, expected attempt,
approved SHA and URL; completed producer records survive later failures.
A newly dispatched run may initially return HTTP 404: the controller waits for
that exact ID with at most four delayed read retries within its existing polling
budget. Once visible, a missing run or any other read error stops monitoring.
Dispatch and upload mutations are never retried by this visibility handling.
For **Package and upload**, an overall green workflow is insufficient: the
controller verifies successful package, seal and upload jobs at the exact run,
attempt and source before recording completion or starting Wait. A skipped,
missing or unbound upload stops the controller for reconciliation. The upload
job explicitly tolerates skipped optional archive ancestors while requiring all
three direct prerequisites to succeed and refusing cancellation.
The shell adapter streams those records only to an existing, owned, non-symlink
`step_summary_*` command file beneath the runner's canonical temporary directory.
Preserve those child run URLs and the package receipt. A failed, timed-out or ambiguous dispatch/upload
requires read-only **Status**/**Wait** reconciliation with the same coordinate;
the controller does not retry writes or select a new build automatically. If main
moves, the pinned request fails closed. Installation, credentials, required
approvals and an actual App-triggered delivery are live acceptance gates; checked-in
source alone does not establish that the Bot is enabled.

专用 Bot 只负责受限触发和状态跟踪，继续使用既有签名、上传、验包与防重复机制。
管理员从当前 main 发起；打包上传成功后，自动等待同一版本/build 的 Apple 处理。
失败或结果不明时保留原始运行和回执，先查询对账。公开 Release、外测分发与正式送审
保持管理员显式操作，不能由 Bot 自动推进。

The checked-in Actions, release scripts and Fastlane lanes execute independently
of an AI assistant. Once the exact current main has passed admission and signing
materials are configured, an Admin selects **Simple → Package and upload**, fills
in **Version**, **Build** and **Product**, and keeps **cloud** as the signing mode.
The read-only precheck queries whether Apple already has that version/build.
After the Development archive and its handoff pass verification, the package job
records permanent `export-start`. Cloud export then checks capacity and exports;
a failure at that point leaves the coordinate occupied. Package verification,
sealing and upload of the original follow. If a protected Environment has approval
rules, its jobs wait for that approval.

日常发包无需 AI 参与。已通过准入的当前 main 和签名材料就绪后，管理员选择
**Simple → Package and upload**，填写版本、build 和包型，沿用 **cloud**。
只读预检查询 Apple 是否已有该版本/build。Development 归档和交接文件验证通过后，
打包作业写入永久 `export-start`，随后云导出检查容量并导出；此时失败仍保留占号。
后续验包、封存并上传原件。如受保护环境配置了审批，相关作业会等待批准。

Use **Status** or **Wait** for the same version/build to read Apple's processing
result. A timeout or uncertain transport result requires query and reconciliation;
it does not authorize another upload. Certificate renewal, permission changes and
source review are separate maintenance work. The package job currently runs on
self-hosted macOS and attempts to copy verified deliverables to that account's
Downloads catalogue, or the configured `GCSA_DELIVERY_ROOT`. Check the target for
the required files first. If the copy is missing, download and verify the retained
original artifact, then run the copy command above with its independently retained
manifest digest on the machine that needs the catalogue.

上传后用相同版本/build 的 **Status** 或 **Wait** 回读 Apple 处理结果；超时或运输结果
不明时先查询对账。证书续期、权限变更和源码审查另行处理。当前打包使用 self-hosted
macOS，自动尝试复制到该运行账号的 Downloads 或配置的 `GCSA_DELIVERY_ROOT`。
先核对目标所需文件；缺少副本时，再下载并验证原始 artifact，使用独立保留的 manifest
摘要，在需要归档的机器上运行上述复制命令。

### Manual signing keychain / 手动签名钥匙串

The temporary signing keychain is added alongside the runner user's existing
search entries, preserving installed Apple intermediate certificates. Setup
verifies the configured signer with the local code-signing trust policy before
packaging. Cleanup deletes the task keychain and retains existing or concurrently
added entries; it does not restore an old global search-list snapshot.

临时签名钥匙串保留原有搜索项；证书链验证失败会在打包和永久占号之前停止。
清理仅删除本任务的钥匙串，不覆盖其他作业更新后的搜索列表。
