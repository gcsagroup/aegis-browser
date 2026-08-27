// Synthetic mining-shaped fixture with renamed locals; never execute.
export async function z(a) {
  const b = new Worker("/synthetic-worker-b.js");
  const c = new WebSocket("wss://miner-beta.invalid/socket");
  c.send("mining.authorize");
  const d = await WebAssembly.compile(a);
  return { b, d };
}
