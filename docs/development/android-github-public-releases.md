# Aegis Android GitHub public releases

This workflow publishes GitHub tags and Releases from an already uploaded Android Release package. It does not build a new App Bundle. The Admin-gated `Android Delivery · Bot` controller is the entry point.

## Upstream promotion, then live testing

Ship the Android delivery and GitHub public-release implementation through a fork branch PR into `gcsagroup/aegis-browser` `main`. Credential-free contracts and the Android matrices under `scripts/release/test_android*.py` / `scripts/ci/tests/android-*.test.mjs` must stay green on that PR. Privileged Play upload, candidate Draft, and public GitHub release remain fail-closed on canonical `gcsagroup/aegis-browser` / `1348409663` and current `main`. Do not enable `AEGIS_ANDROID_RELEASE_ENABLED` or `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED` until the gates below exist after merge; live package, signing, and channel uploads are exercised on upstream after that merge.

## Operations

In **Actions → Android Delivery · Bot**, choose:

- **Preview GitHub release** with product **Release** to run a read-only preview of the prerelease.
- **Publish prerelease** with product **Release** to create the public tag and a GitHub prerelease. It does not become Latest, and it does not wait for the production Environment.
- **Promote to stable** with product **Release**, after review, to mark that same release official. The Admin who starts the controller may approve the exact promotion plan. Alpha and Beta packages are not published.

Each operation first runs **Release Wait**, a read-only Play `generatedApks` query. Publication is allowed only for a recent `VALID` versionCode whose sealed Release package, Play draft records, and status evidence match current `main`. There is no preview-only Android coordinate. The producer must be current `main`.

The public tag is `android/<version>-release.<versionCode>`, for example `android/7.2.0.339-release.2007000339`. The first publication sets `prerelease=true` and `make_latest=false`. Promotion keeps that tag and changes the same GitHub Release to `prerelease=false` with `make_latest=false`. The stable preview shows the exact GitHub Release ID and binds it into the approval plan digest. The publisher resolves the public release again when it recomputes the plan and rereads the approved ID immediately before updating. It verifies the public prerelease, tag and asset inventory. A replacement on the same tag requires a fresh preview and approval even when all assets match. The repository-wide Latest entry is reserved for desktop updates. The approval plan digest binds the source commit/tree, package, upload and status runs, both Actions artifact IDs and ZIP SHA-256 digests, the Play build identity, and the public asset hashes. A replaced artifact requires a new preview and promotion approval even when its public contents match. The release identity digest binds the immutable package, upload run, source and public asset hashes, and stays the same across promotion. The stable approval alone includes the GitHub Release ID.

Only the signed AAB, the native symbols zip, an allowlisted public `android-manifest.json`, and its SHA-256 file are published. The public manifest omits the upload certificate and the signature file. The sealed package keeps those privately. The packaging job builds `chrome_public_bundle` from the verified Chromium and V8 trees in a fresh run-specific output directory. Before signing, it checks the application ID, versionCode and non-debuggable setting in the built base manifest. Release enables native symbols for that build and packages libraries from its own `lib.unstripped` directory. After the immutable package record is written, a step on the same producer attempts to remove that run’s build output. A failed build or failed record or ownership check leaves the output in place. A retirement failure marks that step failed and emits a warning while allowing the package job to succeed. Receipt eligibility still requires the exact successful first-attempt package job.

Full delivery imports and retains the exact package archive before contacting Play. It verifies the recorded run, job, artifact digest and source tree against the admitted main commit. The producer checks the sealed ZIP and its members against the import size limits before reserving a versionCode. Copy the package receipt from the successful packaging job to start a separate Upload. The receipt remains usable if a later job failed before a Play upload intent was recorded. For **distribute** or **submit**, copy the receipt from a successful upload run. Both stages verify the immutable Play draft result and the successful store job for that run. The workflow rechecks current main before signing, reserving a versionCode and writing to a Play edit. Public Release verification supports packaging and upload in separate runs. Candidate Draft and public prerelease staging both verify the tag and live draft before each asset write. Candidate Draft then downloads and hashes the complete asset inventory.

Every new package requires an unoccupied application versionCode. The versionCode-based records use the `android-delivery-v2/` namespace and require the original `android-delivery/` namespace to be empty. If legacy records exist, reconcile those reservations before enabling the new workflow.

Simple **Package and upload** for Release sends the AAB to the Play `internal` track as a `draft`. It does not roll out production. Alpha stays on `internal`. Beta may use `internal` or `beta`. Production `completed` is only the explicit Full **submit** stage, and only after Play already reports `VALID`.

## Required repository configuration

The workflows stay disabled unless `AEGIS_ANDROID_RELEASE_ENABLED` and, for GitHub publication, `AEGIS_ANDROID_GITHUB_RELEASE_ENABLED` are exactly `true`. Do not enable them until the gates below exist on `gcsagroup/aegis-browser`. This source change does not create a ruleset, Environment, variable, tag, or Release, and it does not publish anything.

1. Create an active tag ruleset from [`.github/android-public-release-tag-ruleset.json`](../../.github/android-public-release-tag-ruleset.json). Keep Admin as the only bypass. Protect tag update and deletion. Leave tag creation unrestricted so the job-scoped Actions token can create a new tag. The ruleset include is `refs/tags/android/*` and does not cover `candidate/android/*`.
2. Create the `aegis-android-github-production` Environment. Require one or more named User reviewers, leave **Prevent self-review** off so the initiating Admin can approve, disable **Allow administrators to bypass configured protection rules**, and restrict deployment to protected branches. Prerelease publication does not enter this Environment.
3. Set `AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS` to the comma-separated numeric IDs of the promotion reviewers. Each current Environment reviewer and the approver must remain a current repository Admin and be in that list. The initiating Admin may be that approver.
4. Set `AEGIS_ANDROID_DELIVERY_BOT` to the pinned App `{actorId, appId, slug}`, `AEGIS_ANDROID_BOT_INSTALLATION_ID`, and the `AEGIS_ANDROID_BOT_PRIVATE_KEY` secret. The installation token is limited to Actions write and contents read. Create the `aegis-android-bot` Environment for the controller. Do not widen the GitHub App beyond dispatch.
5. Keep the existing Play environments: `aegis-release-android` for packaging, `aegis-play` for draft upload and status, `aegis-android-distribute`, `aegis-android-submit`, and `aegis-android-draft` for a candidate-tag draft. Runners stay off until `AEGIS_ANDROID_RELEASE_RUNNERS_READY` is exactly `true`.

The promotion approval job uses the protected Environment and has no repository write token. The publisher enters the queue `android-public-release-<repository>` only after that job succeeds. Prerelease publication skips the approval job and enters the same queue. The Environment approval comment must be exactly `publish <plan SHA-256>` from the promotion preview summary. The plan is recomputed after approval and must have the same digest.

## Safety and recovery

The release workflow accepts only first-attempt App dispatches on canonical `main`. A preview does not use the publication queue. The controller records the child run ID and exact inputs in `android-github-release-dispatch-<run>-1`, and the child checks that receipt before proceeding. The prerelease job verifies the package artifact, manifest, Play draft intent and result, fresh Release Wait, and tag ruleset before creating the annotated tag and public prerelease. Promotion verifies those same bytes and the deployment approval, then clears the prerelease flag while keeping the Android release off Latest. It does not create a second tag.

Assets upload to a draft. The publisher re-reads every asset digest before making the release public. An existing tag or release is reused only when its annotation, identity digest, metadata, and SHA-256 match. If a GitHub or Play mutation response is ambiguous, retain the run URL and reconcile by readback before starting another mutation.

`versionCode` must be between 1 and 2100000000, and `versionCode % 10000` must equal the fourth product-version component. The committed example is `7.2.0.339` / `2007000339`. Do not recompute it from the major version.
