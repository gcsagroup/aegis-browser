// API 请求在用户授权的门户标签页的隔离脚本环境内执行。扩展不申请 Cookie 权限，
// 不接收会话 Cookie 或 CSRF，账号、站点和具体 API 均在请求发出前核对。
export async function portalRequest(
  tabId,
  origin,
  collection,
  accountId = "",
  update = null,
) {
  const [reply] = await globalThis.chrome.scripting.executeScript({
    target: { tabId },
    world: "ISOLATED",
    args: [origin, collection, accountId, update],
    func: async (trustedOrigin, kind, expectedUser, change) => {
      if (location.origin !== trustedOrigin || window.top !== window)
        return { error: "origin" };
      const options = {
        credentials: "same-origin",
        cache: "no-store",
        redirect: "error",
      };
      const session = await fetch("/api/v1/auth/session", options);
      if (!session.ok) return { error: session.status === 401 ? "signin" : "network" };
      const { data } = await session.json();
      const user = data?.principal;
      if (user?.kind !== "user" || !user.id || (expectedUser && user.id !== expectedUser))
        return { error: "account" };
      if (kind === null) return { id: user.id, email: user.email };
      if (!["bookmarks", "preferences"].includes(kind)) return { error: "invalid" };
      const result = await fetch(
        "/api/v1/me/browser-sync/" + kind,
        change
          ? {
              ...options,
              method: "PUT",
              headers: {
                "Content-Type": "application/json",
                "X-CSRF-Token": data.csrf_token,
              },
              body: JSON.stringify(change),
            }
          : options,
      );
      if (!result.ok)
        return {
          error:
            result.status === 409
              ? "conflict"
              : result.status === 401
                ? "signin"
                : "network",
        };
      return (await result.json()).data;
    },
  });
  if (!reply?.result || reply.result.error)
    throw new Error(reply?.result?.error || "network");
  return reply.result;
}
