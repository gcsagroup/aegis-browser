// Synthetic benign control with renamed locals; never executed.
export async function q(a) {
  const b = new Worker("/image-codec-worker.js");
  const c = await WebAssembly.instantiate(a);
  b.postMessage({ type: "decode", ready: Boolean(c) });
  return b;
}
