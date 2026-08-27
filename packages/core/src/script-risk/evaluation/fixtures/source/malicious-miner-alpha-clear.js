// Synthetic mining-shaped fixture. It is parsed as text and must never execute.
export async function syntheticMiningFixture(bytes) {
  const worker = new Worker("/synthetic-miner-worker.js");
  const socket = new WebSocket("wss://miner-alpha.invalid/socket");
  socket.send("mining.subscribe");
  const module = await WebAssembly.instantiate(bytes);
  return { worker, module };
}
