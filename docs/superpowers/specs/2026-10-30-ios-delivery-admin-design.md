# iOS Delivery Consolidation and Administrator Authorization

## Intent and scope

The user requested fewer duplicate iOS packaging/upload workflows and repository Admin-or-higher operators. They explicitly asked to finish the existing Tag/Draft and historical TF work first. That campaign is now complete at upstream0375a632a51eddac2518cbeedb00b2d55ae9ddc4/treeac726bccad79f246461aedd8a947e92f998352c9: nine upstream method/profile rows plus ten original-source uploads passed. Its evidence/workspace remain independent.

Use inline implementation in a new isolated worktree, one iOS follow-up PR, normal merge only after required checks and added iOS checks pass, then real merged-source retests. No public release, new external Beta Review or formal App Store submission. Other platforms, shared host services, VM/proxy service state and main branch protections are outside scope. Keep internal/external real free space at least8/15GiB respectively.

## Approaches and implementation decision

1. **One Delivery plus existing Validation and Coverage (selected):** merge the three delivery entrypoints, retain two distinct uncredentialed quality purposes. It removes duplication within the user's packaging/upload scope and preserves existing quality identities.
2. One Delivery plus merged quality workflow: reduces another sidebar item, but unnecessarily changes coverage scheduling and validation identity.
3. One workflow for delivery and all PR/coverage activity: conflates untrusted PR checks with protected delivery and increases conditional security complexity.

The implementation choice is the agent's scoped proposal under the user's instruction to continue. No additional feature such as implicit package-and-upload or automatic tag upload is introduced. Stages remain explicit.

## Workflow contract

- Create `.github/workflows/ios-delivery.yml`, name `iOS Delivery`, triggered by `workflow_dispatch` and candidate/ios/* tag pushes. Remove ios-release.yml, ios-testflight.yml and ios-candidate.yml after replacing all callers/trust paths.
- Manual `operation`: package(default), upload, wait, status, metadata, compliance, distribute. Profiles alpha(default), beta, release. Explicit version/build; existing-package operations require original package run/current attempt and independently retained manifest SHA256. State-run and stage-input fields preserve the existing receipt chain.
- Destination `auto` resolves to artifacts for package and testflight for upload/read/compliance/metadata. Distribute requires explicit internal/external destination and existing groups. Alpha external is rejected before any protected job. Private Draft requires exact existing candidate tag matching profile/version/build/source.
- A tag derives package identity and selects private Draft only. It never implicitly uploads or distributes to TF.
- Normalize and validate input once in an uncredentialed admission job. No shell interpolation of inputs. Role authorization and current source/quality admission must both succeed before a protected job is queued.
- Reuse package → optional Draft and existing-state import → protected store job chains. A package workflow run completes before it is selected by a later upload operation; no new same-run package/upload transport protocol is needed. Draft retains current-run completed-producer verification.
- Retain exact repository, source SHA/tree, run/attempt, package producer, manifest/asset digests, hostile ZIP checks and immutable stage intents. Unknown mutations and later attempts cannot be replayed. Permission-denied/pre-stage failures with conclusively skipped store jobs must not poison a later administrator's stage admission.
- Distinct signing/Draft/store environments and minimal per-job token permissions remain. Keep source admission at current upstream main and successful exact-source quality. Fork delivery remains retired; the new privileged Delivery workflow and local runner launcher accept only canonical upstream repository ID1348409663. Fork PR/quality checks remain uncredentialed.
- Keep `iOS Release Validation` and `iOS Coverage`. Automatic PR/push validation remains uncredentialed and available to contributors. Their manual dispatches require Admin before expensive commands; no release environment or ASC/signing material is added to quality jobs.

## Administrator authorization

- Interpret Admin-or-higher as the effective repository base Admin grant, including organization-owner grants. Maintain/Write/Triage/Read/none and unknown grants are denied. Do not grant access by username allowlist, role title, author association or user-provided input.
- For CI derive the original and triggering actors from the authoritative current Actions run, cross-check immutable runtime identity/run/attempt/repository/source fields, and require **both** actors to be current Admins. This prevents a non-Admin rerun inheriting the original Admin identity.
- Use a GitHub installation-token-compatible API: the paginated repository collaborators list filtered to admin, with explicit `permissions.admin=true` and matching principal ID/login. The documented single-user permission endpoint is usable for local user tokens but must not be assumed compatible with GITHUB_TOKEN.
- For local Fastlane admission, resolve the actual authenticated token user and verify its effective Admin grant. `plan` stays uncredentialed. Authorize before signing inputs or ASC authentication; recheck at privileged stage boundaries. The owned runner launcher must verify its actual GitHub CLI operator before any private-key probe/registration.
- Permission errors, incomplete inventories, mismatched identities and unknown context deny access. No broad PAT is installed in Actions. Use existing GITHUB_TOKEN with Metadata read; add a credential-free CI capability read to verify actual installation-token support without disclosing the administrator roster.
- GitHub's native dispatch threshold is Write; a lower-role user may see/click the button, but authorization fails before protected jobs or side effects. Historical workflow runs/artifacts remain; obsolete entrypoints are disabled if GitHub still indexes them.

## Encryption declaration

The user showed the ASC encryption prompt. This iOS source retains the previously confirmed Apple-OS-only crypto implementation. Reviewed usage includes Apple CryptoKit AES.GCM and SHA256, rather than an assertion that no encryption occurs. Its native implementation and bundled libraries/resources are unchanged by this task.

- Add boolean `ITSAppUsesNonExemptEncryption=false` to `apps/ios/AegisApp/Info.plist` (the referenced authoritative plist; project.yml points to it).
- Verify the exported signed app's declaration against its committed source plist; a missing/contradictory/non-boolean declaration fails when the source declares it. Preserve verification of historical packages against historical source where the key was absent.
- Do not rewrite/resign prior IPA files. New package/source digests will change. Record the new native-input digest and prove the only native input change is the declarative plist key, with the crypto implementation unchanged.
- Real TF acceptance must read `usesNonExemptEncryption=false` **before** any explicit compliance PATCH, proving the upload itself carries the declaration. Future crypto implementation/library changes require reassessment of the source declaration.

## Validation and delivery

- RED/GREEN tests for all permission ranks, spoofed/runtime actor mismatch, original Admin + lower-role rerunner, lower-role original + Admin rerunner, API denial/pagination, guarded job dependencies and zero privileged work on denial.
- Test manual/tag normalization, exact tag identity, profile/destination matrix, old/new workflow provenance, immutable state/rerun guards and denied-run non-poisoning.
- Test source/exported encryption plist boolean matching, mismatch/missing/type rejection, legacy absent-key compatibility and unchanged native code/resources apart from the one key.
- Run relevant Ruby/Python/Node suites, actionlint, full quality and exact new-source uncredentialed iOS archive. Fresh whole-branch security review before normal PR merge; repair material findings.
- After merge wait for fresh main gates. Live administrator acceptance covers local Fastlane Alpha, unified manual delivery Beta, candidate Tag Release, plus default-Alpha unified delivery. Each actually signs/packages/uploads with a fresh live-checked build identity, downloads/verifies artifacts, reads TF VALID/audience and automatic encryption declaration, and exercises later state stages on the same upload. Tags additionally verify private Draft/assets. Every generated acceptance IPA is uploaded; no duplicate upload identity.
- Non-Admin/rerun denial is proven by deterministic faithful authorization and DAG tests; do not impersonate users, change memberships or invent real lower-role account evidence. Run the actual metadata-capability read under GITHUB_TOKEN.
- Bind evidence to the new merged SHA/tree. Keep prior source37 nine-row acceptance separate. Physical-device proof remains not_verified; external Beta Review/formal review are contract-only.

## References

- GitHub collaborator API: https://docs.github.com/en/rest/collaborators/collaborators
- GitHub dispatch permissions: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow
- Apple OS encryption exemption/declaration: https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations

Builder check: a fresh read-only design reviewer reported "nothing important left". Inline implementation remains the preserved execution method; the user already authorized the consolidation and continuation.

Security review amendment: candidate tag provenance is enforced outside workflow code with an Admin-only creation/update/deletion ruleset for refs/tags/candidate/ios/**/*, role name independently read back before activation. Passed main source is trusted; shared-main governance is outside this platform-only change. Cross-source denied runs are classified against their own authoritative source/attempt/job identities, without requiring their SHA to equal the current run.
