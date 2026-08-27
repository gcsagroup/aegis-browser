// Synthetic benign control. Parsed as text by the evaluator; never executed.
export async function decodeImage(bytes) {
  const worker = new Worker("/image-codec-worker.js");
  const codec = await WebAssembly.instantiate(bytes);
  worker.postMessage({ type: "decode", codec: Boolean(codec) });
  return worker;
}
