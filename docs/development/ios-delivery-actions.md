# iOS Delivery Actions operator guide / iOS 交付操作指南

In the upstream `gcsagroup/aegis-browser` repository, open **Actions**, select **iOS Delivery · Simple** or **iOS Delivery · Full**, choose **Run workflow**, and select the `main` branch. The original operator and any rerunner must have effective repository Admin access.

在上游仓库 `gcsagroup/aegis-browser` 打开 **Actions**，选择 **iOS Delivery · Simple** 或 **iOS Delivery · Full**，点击 **Run workflow** 并选择 `main` 分支。首次发起与重新运行均要求实际的仓库 Admin 权限。

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

For existing-package stages, wait for the whole previous run to succeed, copy the complete **Delivery receipt** from its **Summary**, leave **Product** on **Auto**, and leave **Version** and **Build** blank. Retain the original receipt and use the latest successful receipt for the next stage.

操作已有包时，先确认上一轮运行整体成功，再从其 **Summary** 复制完整 **Delivery receipt**。将 **Product** 保持为 **Auto**，留空 **Version** 和 **Build**。保留原始凭据，后续阶段使用同一包最新成功运行的凭据。

For protected environment setup, stage JSON examples and recovery steps, see the [iOS release operations reference](ios-release.md).

受保护环境配置、阶段 JSON 示例及故障恢复步骤见 [iOS 发布操作参考](ios-release.zh-CN.md)。
