const parentOrigin = 'chrome://aegis-capture';
const assets = new URL('ocr_assets/', location.href);
const workerPath = new URL('worker.min.js', assets).href;

if (globalThis.trustedTypes) {
  globalThis.trustedTypes.createPolicy('default', {
    createScriptURL(value) {
      if (value === workerPath) return value;
      throw new TypeError('Unexpected OCR worker');
    },
  });
}

async function recognize(event) {
  if (event.origin !== parentOrigin || event.source !== parent) return;
  const {image, traditional} = event.data ?? {};
  if (!(image instanceof Blob) || image.type !== 'image/png' ||
      image.size === 0 || image.size > 8 * 1024 * 1024) return;
  window.removeEventListener('message', recognize);
  const languages = traditional ? ['chi_tra', 'eng', 'chi_sim'] :
                                  ['chi_sim', 'eng', 'chi_tra'];
  let worker;
  try {
    let onWorkerError;
    const failed = new Promise((_, reject) => { onWorkerError = reject; });
    worker = await Promise.race([failed, globalThis.Tesseract.createWorker(languages, 1, {
      workerPath,
      workerBlobURL: false,
      corePath: new URL('tesseract-core-lstm.wasm.js', assets).href,
      langPath: assets.href,
      cacheMethod: 'none',
      errorHandler: onWorkerError,
    })]);
    const {data} = await Promise.race([failed, worker.recognize(image)]);
    parent.postMessage({type: 'result', text: data.text.trim()}, parentOrigin);
  } catch (_) {
    parent.postMessage({type: 'result', text: null}, parentOrigin);
  } finally {
    await worker?.terminate();
  }
}

if (parent !== window) {
  window.addEventListener('message', recognize);
  parent.postMessage({type: 'ready'}, parentOrigin);
}
