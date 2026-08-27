// Synthetic string-splitting fixture for an expected static-analysis evasion; never execute.
export async function syntheticEncodedProtocol(bytes) {
  const worker = new Worker("/synthetic-worker-b.js");
  const socket = new WebSocket("wss://miner-beta.invalid/socket");
  socket.send(["mining", "authorize"].join("."));
  const module = await WebAssembly.compile(bytes);
  return { worker, module };
}
