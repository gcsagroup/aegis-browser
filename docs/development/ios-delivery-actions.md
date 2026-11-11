# iOS Delivery Actions operator guide / iOS 交付操作指南

In the upstream `gcsagroup/aegis-browser` repository, open **Actions**, select **iOS Delivery · Simple** or **iOS Delivery · Full**, choose **Run workflow**, and select the `main` branch. The original operator and any rerunner must have effective repository Admin access.

在上游仓库 `gcsagroup/aegis-browser` 打开 **Actions**，选择 **iOS Delivery · Simple** 或 **iOS Delivery · Full**，点击 **Run workflow** 并选择 `main` 分支。首次发起与重新运行均要求实际的仓库 Admin 权限。

## Signing mode / 签名模式

New packages default to **cloud** in both forms, the CLI, Fastlane and candidate
tags. Use **manual** explicitly for the existing certificate/profile fallback:
Actions **Signing mode → manual**, CLI `--signing-mode manual`, Fastlane
`signing_mode:manual`. Cloud packaging runs on an admitted GitHub-hosted macOS
runner without importing a Distribution P12. Cloud failure stops the attempt;
manual is an operator selection, with a new run ID and an unused build.

两个表单、CLI、Fastlane 和 candidate tag 的新包均默认 **cloud**。显式回退选择：Actions 的 **Signing mode → manual**、CLI 的 `--signing-mode manual`、Fastlane 的 `signing_mode:manual`。cloud 使用获准的 GitHub-hosted macOS runner，不导入分发 P12；失败后停止，由操作者核对状态并选择 manual、未占用 build 与新 run ID。

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

If **Wait** times out, the run fails and retains the last observed Apple state in its Summary and status artifact. Use **Status** or **Wait** again to check that same build; do not upload it again.

**Wait** 超时仍会失败，并在 Summary 和状态 artifact 中保留最后一次 Apple 状态。使用 **Status** 或 **Wait** 再次查询同一构建，不要重新上传。

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
must already be unlocked and available to headless `codesign`.

Private configuration ancestors must be owned by the runner account or root and
exclude directory mutation by other accounts, including extended ACL grants.
Writable ancestor ACL entries are accepted only when native membership lookup
identifies their principal as the runner account or root; groups and unknown principals fail closed.
Root/account-owned sticky temporary ancestors are allowed; the private signing
directory and configuration file still require their exact private modes and no ACLs.
Direct Fastlane/PoC inline Development archives apply the same explicit selection
and signed archive verification. The production transfer workflow provides the
separate archive/export jobs.

This selection changes only Development archive signing. Xcode 26.6's installed
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
