# Aegis iOS GitHub public releases

This workflow publishes GitHub tags and Releases from an already uploaded iOS package. It does not build or upload a new IPA. The existing Admin-gated `iOS Delivery · Bot` controller remains the entry point.

## Operations

In **Actions → iOS Delivery · Bot**, choose:

- **Preview GitHub release** with product **Beta** or **Release** to run a read-only preview.
- **Publish Beta release** with product **Beta** to create an iOS Beta prerelease.
- **Publish stable release** with product **Release** to request a stable publication. A separate Production Environment Admin must approve the exact preview plan.

Each operation first runs **Release Wait**, a read-only Apple query that emits only the build status needed for the release. It hashes the Apple build ID and discards raw upload and group records. Publication is allowed only for a recent `VALID`, unexpired build whose exact uploaded package and Apple status evidence match the same repository main commit. The current `1.1.0 (8)` package is preview-only. Its producer may be an ancestor of current main as long as its original package and upload evidence remain available. Release Wait runs on current main. The IPA resources are checked with the verifier and license inventory from the sealed producer tree.

The tag names are `ios/<version>-beta.<build>` and `ios/<version>-release.<build>`. Beta uses `prerelease=true` and `make_latest=false`. Stable uses `prerelease=false` and `make_latest=true`. The approval plan digest binds the source commit/tree, package and status runs, both Actions artifact IDs and ZIP SHA-256 digests, Apple build, channel, and public asset hashes. A replaced artifact requires a new preview and stable approval even when its public contents match. A separate release identity digest binds the immutable package/source and public asset hashes, so a new Apple Wait can reconcile the same published bytes without changing the tag annotation or release notes.

Only the unchanged IPA and dSYM archive, an allowlisted public `ios-manifest.json`, and its SHA-256 file are published. The Release workflow does not attach original signing manifests, proof files, or Apple records to the public Release or link to the original artifacts in its preview. Existing sealed package artifacts are stored by the producer in the public repository Actions system and may be downloadable by signed-in readers. Moving that evidence to access-controlled storage requires a separate migration and credential decision before treating it as private.

## Required repository configuration

The workflow is disabled unless the repository variable `AEGIS_IOS_GITHUB_RELEASE_ENABLED` is exactly `true`. Do not enable it until all gates below are configured on `gcsagroup/aegis-browser`. To disable publication, turn off the variable and cancel outstanding controller and release runs, including runs waiting for approval. GitHub can retain the value from when a workflow was queued.

1. Create an active tag ruleset from [`.github/ios-public-release-tag-ruleset.json`](../../.github/ios-public-release-tag-ruleset.json). Keep Admin as the only bypass. Before enabling the workflow, an Admin must read back the live bypass list in GitHub settings. GitHub omits that list from read-only API responses. The workflow checks the live rule conditions and enforcement and validates the bypass list when GitHub returns it. Protect tag update and deletion; leave tag creation unrestricted so the job-scoped Actions token can create a new tag. Keep the separate candidate-tag ruleset unchanged.
2. Create the `aegis-ios-github-production` Environment. Require one or more named User reviewers, enable **Prevent self-review**, disable **Allow administrators to bypass configured protection rules**, and restrict deployment to protected branches. The workflow reads back these settings before a stable publication.
3. Set the repository variable `AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS` to the comma-separated numeric IDs of the stable reviewers. The workflow checks this list during stable preview and publication. Each current Environment reviewer and the approver must remain a current repository Admin; the approver must be in the live reviewer set and differ from every Admin who initiated or reran the controller.
4. Confirm the existing `AEGIS_IOS_RELEASE_ENABLED` gate and required current-main quality checks are enabled. The new workflow does not change the GCSA GitHub App installation permissions. It uses that App only to dispatch Actions; only the publication job receives `GITHUB_TOKEN` `contents:write`.

The stable approval job uses the protected Environment and has no repository write token. The separate publisher enters the shared queue only after that job succeeds. The stable Environment approval comment must be exactly `publish <plan SHA-256>` from the preview summary. The plan is recomputed after approval and must have the same digest.

The stable publisher reads the Environment settings and requires the API to report administrator bypass disabled. If the setting cannot be verified, stable publication fails closed; verify it in the Environment settings before enabling the feature.

## Safety and recovery

The release workflow accepts only first-attempt App dispatches on canonical main and queues publishing jobs per repository. A preview does not use the publication queue. The controller records the child run ID and exact inputs in a sealed artifact, then links to the child run. The child checks the receipt before proceeding. Follow the child for preview, approval, and publication status. The preview performs reads only. The publishing job verifies the exact source, package artifact, manifest, IPA identity, permanent upload intent/result, fresh Apple status, tag ruleset, and (for stable) the run-specific deployment approval before creating a tag or release. The package and Apple status artifact ZIPs are downloaded by artifact ID and checked against their Actions artifact digests before either payload is extracted or read.

Assets are uploaded to a draft. The Bot verifies all four remote asset hashes before making the release public or setting Latest. The Bot owns drafts for its `ios/*` tags through publication. Keep human and other automation edits outside those drafts while publication is active. GitHub does not offer an atomic publish operation conditioned on the asset hashes, so the workflow reads the draft again immediately before promotion and verifies the public result. An existing tag, draft, release, or asset is reused only when its annotation, release identity digest, metadata, and SHA-256 match. Stable approval still binds to the exact approval plan digest, including the fresh status run. Conflicts stop the publisher. A read-only preview cannot see all drafts and reports draft status as unverified when it sees no public release. If a GitHub mutation has an ambiguous response, retain the run URL and reconcile the tag/release/asset state by readback before starting another mutation. Do not rerun a failed mutation job blindly.

No GitHub ruleset, Environment, repository variable, tag, or Release is configured or created by this source change. In particular, `1.1.0 (8)` is blocked from publication and remains preview-only.
