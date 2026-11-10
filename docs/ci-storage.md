# CI storage placement

Unsigned iOS validation keeps the runner service, credentials, checkout and Actions control files on their existing paths. Self-hosted archive data, DerivedData, Swift package downloads/cache, Clang modules and task temp use a fresh job directory on an enrolled external APFS volume. The self-hosted job requires 20 GiB available on that volume. GitHub-hosted Macs retain their existing ephemeral runner-temp route; the external-volume gate does not apply there. Chromium native-build capacity and qualification gates are unchanged.

Enroll each self-hosted Mac in the local, untracked file `~/.config/gcsa-ci/aegis-volume-identity.json`, owned by its runner user, mode `0600`, without ACL grants or symlinks. The helper uses the actual account home from the OS user database; a job's `HOME` cannot select another enrollment. CLI calls use isolated Python. The parent directories must be controlled by that user or root and not group/world writable. Do not commit or copy the enrollment to another host.

```json
{
  "schema_version": 1,
  "mount_point": "/Volumes/EnrolledDevelopmentDisk",
  "volume_uuid": "11111111-2222-4333-8444-555555555555",
  "runner_roots": {
    "example-mac-runner": "gcsa-ci/aegis/slot-mac-01"
  }
}
```

Replace both example identity values and the runner name with the actual host readback. The helper dynamically verifies the configured mount/UUID, external APFS backing, enabled ownership, writable state and distinct per-runner roots. Root overlap checks conservatively reject case-folded and Unicode-equivalent aliases on either APFS variant. Private files reject actual ACL entries even when an xattr masks the permissions marker; directories reject mutation/delete grants and inheritable ACLs before private data is created. Base, jobs and final job directories must remain on the admitted device. A missing or mismatched enrollment fails closed; it does not fall back to the internal disk.

Dynamic mount/cache paths support spaces and Unicode. Control characters and artifact-glob metacharacters (`*?[]{}()!` and backslash) are rejected before build data is created, because Actions output records are line-based and the upload action treats paths as glob expressions. This restriction also applies to the hosted temp path; it avoids missing evidence or matching another job's files. Check enrollment without impersonating CI:

```sh
python3 -I -B scripts/ci/ios-ci-storage.py doctor --runner-name ACTUAL_RUNNER_NAME
```

Each admitted job receives a unique directory, including retries. Existing job data is retained for diagnosis; this helper does not delete previous caches, archives or recovery inputs. Its private `.storage-state.json` stays on the host. Uploaded `storage-receipt.json` contains the enrollment digest, source SHA/tree and run identity, without the host mount, UUID or local paths.

After the existing archive verifier succeeds, the workflow retains `Aegis.xcarchive.zip`, `unsigned-artifact.json`, the public storage receipt and the build log. The manifest binds the archive SHA256 to the actual clean checkout and run/attempt/job. Tracked changes and untracked source are rejected; ignored inputs in the iOS and shared browser-overlay resource trees are rejected too. Generated `.artifacts` and dependency directories outside those build inputs remain separate. Volume enrollment and directory identity are rechecked before sealing. A failed job can retain logs and partial evidence; consumers must require the successful exact-source job and complete matching manifest/archive pair. These files prove unsigned archive validation only. Signing, upload, protected delivery workflows, physical-device acceptance, the frozen Android producer, macOS's Android prerequisite and Windows scope are unchanged.
