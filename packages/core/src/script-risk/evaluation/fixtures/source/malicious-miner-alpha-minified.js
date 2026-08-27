// Synthetic mining-shaped fixture. It is parsed as text and must never execute.
export async function m(b){const w=new Worker("/synthetic-miner-worker.js"),s=new WebSocket("wss://miner-alpha.invalid/socket");s.send("mining.subscribe");const x=await WebAssembly.instantiate(b);return{w,x}}
