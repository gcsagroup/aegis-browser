// 同步状态按设备、站点、用户和集合隔离。服务端版本与本地摘要共同识别并发修改。
import { fingerprint, seal, unseal } from "./account_crypto.js";

/** 首次双端均有资料或离线修改冲突时，交由本人明确选择。对旧版本的上传由服务端拒绝。 */
export async function synchronize(call, user, kind, password, choose) {
  const binding = JSON.stringify(["aegis-link-v1", user.origin, user.id, kind]);
  return navigator.locks.request(binding, async () => {
    const input = { account: user.id, collection: kind };
    const readLocal = () => call("profile", input);
    const current = await readLocal(),
      local = await fingerprint(current);
    const key = "revision:" + binding,
      previous = JSON.parse(localStorage.getItem(key) || "null");
    const remote = await call("read", input);
    let version = remote.version,
      digest = local;
    let action = "upload";
    if (version !== "0") {
      // 即使只是上传，也用用户输入的口令解开现有资料，避免输错口令后重加密覆盖云端。
      const cloud = await unseal(remote.envelope, password, binding);
      const cloudHash = await fingerprint(cloud);
      if (cloudHash === local) action = "same";
      else if (previous?.version === version) action = "upload";
      else if (
        previous?.digest === local ||
        (!previous && kind === "bookmarks" && !current.length)
      )
        action = "download";
      else action = await choose(kind);
      if (action === "download" || action === "restore") {
        if ((await fingerprint(await readLocal())) !== local) throw new Error("conflict");
        await call("profile", {
          ...input,
          value: cloud,
          before: current,
          backup: action === "restore",
        });
        digest = cloudHash;
      }
    }
    if (action === "upload") {
      const envelope = await seal(current, password, binding);
      const saved = await call("write", {
        ...input,
        change: {
          expected_version: version,
          envelope,
        },
      });
      version = saved.version;
    }
    localStorage.setItem(key, JSON.stringify({ version, digest }));
    return action;
  });
}
