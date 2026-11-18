import {sendWithPromise} from 'chrome://resources/js/cr.js';

const locale = navigator.language.toLowerCase();
const language = /^zh-(tw|hk|mo|hant)/.test(locale) ? 2 : locale.startsWith('zh') ? 1 : 0;
const copy = new Map(Object.entries({
  screenshot: ['Full page screenshot', '整页截图', '整頁截圖'],
  recognize: ['Recognize image text', '识别图片文字', '辨識圖片文字'],
  unavailable: ['The page could not be captured.', '无法截取这个网页。', '無法截取這個網頁。'],
  large: ['The page exceeds the capture size limit.', '网页超出整页截图的大小上限。', '網頁超出整頁截圖的大小上限。'],
  crop: ['Crop', '裁剪', '裁剪'],
  cropDone: ['Done cropping', '完成裁剪', '完成裁剪'],
  select: ['Drag to select what to keep.', '拖动选取要保留的区域。', '拖曳選取要保留的區域。'],
  reset: ['Reset crop', '恢复整张', '還原整張'],
  zoom: ['Zoom', '缩放', '縮放'],
  copy: ['Copy image', '复制图片', '複製圖片'],
  save: ['Save PNG', '保存 PNG', '儲存 PNG'],
  share: ['Share image', '分享图片', '分享圖片'],
  shareFailed: ['Could not share. Try saving the image.', '分享失败，可以保存图片。', '分享失敗，可以儲存圖片。'],
  copied: ['Copied', '已复制', '已複製'],
  copyFailed: ['Could not copy. Try saving the image.', '复制失败，可以保存图片。', '複製失敗，可以儲存圖片。'],
  output: ['Recognized text', '识别出的文字', '辨識出的文字'],
  copyText: ['Copy all text', '复制全部文字', '複製全部文字'],
  server: ['Recognize on server', '用服务器识别', '用伺服器辨識'],
  confirm: ['Send this image?', '确认发送图片', '確認傳送圖片'],
  send: ['Send and recognize', '发送并识别', '傳送並辨識'],
  cancel: ['Cancel', '取消', '取消'],
  local: ['Recognizing on this device…', '正在本机识别…', '正在本機辨識…'],
  empty: ['No text found on this device.', '本机未识别到文字。', '本機未辨識到文字。'],
  noLocal: ['Text recognition is unavailable on this device.', '本机识别不可用。', '本機辨識無法使用。'],
  sending: ['Recognizing on server…', '服务器正在识别…', '伺服器正在辨識…'],
  retry: ['Server recognition failed. You can retry.', '服务器识别失败，可以重试。', '伺服器辨識失敗，可以重試。'],
  noText: ['The server found no text in the image.', '服务器未识别到文字。', '伺服器未辨識到文字。'],
  remoteDone: ['Recognized on server.', '已用服务器识别。', '已用伺服器辨識。'],
  settingsChanged: ['Server settings changed. Open the upload preview again.', '服务器设置已变更，请重新打开上传预览。', '伺服器設定已變更，請重新開啟上傳預覽。'],
  limited: ['Crop to a smaller area to send it.', '请裁成更小的区域后发送。', '請裁成更小的區域後傳送。'],
}));

const $ = id => document.getElementById(id);
const t = key => copy.get(key).at(language);
const status = key => { $('status').textContent = key ? t(key) : ''; };
const source = $('source');
const paper = $('paper');
const dialog = $('confirmation');
let selection;
let start;
let cropped = false;
let requestImage;
let remoteBusy = false;
let remoteStarted = false;

function resize() {
  const width = Math.max(1, Math.min(source.naturalWidth, $('preview').clientWidth - 24));
  source.style.width = `${width * Number($('zoom').value) / 100}px`;
}

function renderSelection() {
  const outline = $('outline');
  outline.hidden = !selection;
  if (!selection) return;
  const {left, top, right, bottom} = selection;
  outline.style.inset = `${top * 100}% ${(1 - right) * 100}% ${(1 - bottom) * 100}% ${left * 100}%`;
}

function position(event) {
  const rect = source.getBoundingClientRect();
  const clamp = n => Math.min(1, Math.max(0, n));
  return [clamp((event.clientX - rect.left) / rect.width), clamp((event.clientY - rect.top) / rect.height)];
}

function capturePNG(ocr = false) {
  const {left, top, right, bottom} = selection || {left: 0, top: 0, right: 1, bottom: 1};
  const x = Math.floor(left * source.naturalWidth), y = Math.floor(top * source.naturalHeight);
  const width = Math.ceil(right * source.naturalWidth) - x;
  const height = Math.ceil(bottom * source.naturalHeight) - y;
  if (!width || !height || (ocr && (width > 8192 || height > 8192 || width * height > 12000000))) {
    return Promise.resolve(null);
  }
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const context = canvas.getContext('2d');
  if (!context) return Promise.resolve(null);
  context.drawImage(source, x, y, width, height, 0, 0, width, height);
  return new Promise(resolve => canvas.toBlob(resolve, 'image/png'));
}

function setText(text) {
  $('text').value = text;
  $('copy-text').hidden = !text;
}

async function localRecognition() {
  status('local');
  try {
    const image = await capturePNG(true);
    if (!image || image.size > 8 * 1024 * 1024) { status('limited'); return; }
    const native = await sendWithPromise('aegisCaptureLocalOCR', await base64Image(image));
    const result = native.available ? native : {available: true, text: await recognizeOffline(image)};
    if (remoteStarted) return;
    if (result.text) setText(result.text);
    status(result.text ? '' : result.available ? 'empty' : 'noLocal');
  } catch (_) {
    if (!remoteStarted) status('noLocal');
  }
}

function recognizeOffline(image) {
  const origin = 'chrome-untrusted://aegis-ocr';
  return new Promise((resolve, reject) => {
    const frame = document.createElement('iframe');
    frame.hidden = true;
    frame.src = origin + '/';
    const timer = setTimeout(() => finish(null), 30000);
    function finish(text) {
      clearTimeout(timer);
      window.removeEventListener('message', onMessage);
      frame.remove();
      if (typeof text === 'string') resolve(text);
      else reject(new Error('Offline recognition unavailable'));
    }
    function onMessage(event) {
      if (event.source !== frame.contentWindow || event.origin !== origin) return;
      const message = event.data;
      if (message?.type === 'ready') {
        frame.contentWindow.postMessage({image, traditional: language === 2}, origin);
      } else if (message?.type === 'result') {
        finish(message.text);
      }
    }
    window.addEventListener('message', onMessage);
    document.body.append(frame);
  });
}

function base64Image(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

async function refreshRemoteAvailability() {
  try {
    $('server').hidden = !await sendWithPromise('aegisCaptureGetRemoteDestination');
  } catch (error) {
    $('server').hidden = true;
  }
}

function addEvents() {
  $('crop').onclick = () => {
    cropped = !cropped;
    paper.classList.toggle('cropping', cropped);
    $('crop').textContent = t(cropped ? 'cropDone' : 'crop');
    if (cropped) status('select');
    else status('');
  };
  $('reset').onclick = () => {
    selection = undefined;
    $('reset').hidden = true;
    renderSelection();
  };
  $('zoom').oninput = resize;
  new ResizeObserver(resize).observe($('preview'));
  source.onpointerdown = event => {
    if (!cropped || (event.pointerType === 'mouse' && event.button !== 0)) return;
    start = position(event);
    source.setPointerCapture(event.pointerId);
  };
  function updateSelection(event) {
    if (!start || !source.hasPointerCapture(event.pointerId)) return;
    const [x, y] = position(event);
    if (Math.abs(x - start[0]) * source.naturalWidth < 2 ||
        Math.abs(y - start[1]) * source.naturalHeight < 2) return;
    selection = {left: Math.min(x, start[0]), right: Math.max(x, start[0]),
                 top: Math.min(y, start[1]), bottom: Math.max(y, start[1])};
    renderSelection();
  }
  source.onpointermove = updateSelection;
  source.onpointerup = updateSelection;
  source.onlostpointercapture = () => {
    start = undefined;
    $('reset').hidden = !selection;
  };
  $('copy').onclick = async () => {
    try {
      await navigator.clipboard.write([new ClipboardItem({'image/png': capturePNG()})]);
      status('copied');
    } catch (_) { status('copyFailed'); }
  };
  $('save').onclick = async () => {
    const blob = await capturePNG();
    if (!blob) { status('large'); return; }
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = 'Aegis.png';
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 2000);
  };
  $('share').onclick = async () => {
    const blob = await capturePNG();
    if (!blob) { status('large'); return; }
    const files = [new File([blob], 'Aegis.png', {type: 'image/png'})];
    if (!navigator.canShare?.({files})) { status('shareFailed'); return; }
    try { await navigator.share({files}); }
    catch (error) { if (error.name !== 'AbortError') status('shareFailed'); }
  };
  $('copy-text').onclick = async () => {
    try { await navigator.clipboard.writeText($('text').value); status('copied'); }
    catch (_) { $('text').select(); status('copyFailed'); }
  };
  $('server').onclick = async () => {
    if (dialog.open || $('server').disabled) return;
    $('server').disabled = true;
    try {
      const blob = await capturePNG(true);
      if (!blob || blob.size > 8 * 1024 * 1024) { status('limited'); return; }
      requestImage = await base64Image(blob);
      const destination = await sendWithPromise('aegisCapturePrepareRemoteRequest');
      if (!destination) {
        requestImage = undefined;
        $('server').hidden = true;
        status('settingsChanged');
        return;
      }
      $('confirmed-image').src = 'data:image/png;base64,' + requestImage;
      $('destination').textContent = destination;
      dialog.returnValue = '';
      dialog.showModal();
    } catch (_) {
      status('retry');
    } finally {
      $('server').disabled = false;
    }
  };
  dialog.onclose = () => {
    $('confirmed-image').removeAttribute('src');
    requestImage = undefined;
  };
  $('send').onclick = async event => {
    event.preventDefault();
    if (!event.isTrusted || !requestImage || remoteBusy) return;
    const captured = requestImage;
    dialog.close();
    remoteBusy = true;
    remoteStarted = true;
    $('server').disabled = true;
    status('sending');
    try {
      const result = await sendWithPromise('aegisCaptureRemoteOCRRequiringGesture', captured);
      if (result.text) setText(result.text);
      status(result.settingsChanged ? 'settingsChanged' :
          result.ok ? result.text ? 'remoteDone' : 'noText' : 'retry');
      if (result.settingsChanged) void refreshRemoteAvailability();
    } catch (_) {
      status('retry');
    } finally {
      remoteBusy = false;
      $('server').disabled = false;
    }
  };
}

async function startPreview() {
  for (const [id, key] of Object.entries({
    crop: 'crop', reset: 'reset', 'zoom-text': 'zoom', copy: 'copy', save: 'save', share: 'share',
    'copy-text': 'copyText', server: 'server', 'confirmation-title': 'confirm', send: 'send', cancel: 'cancel',
  })) $(id).textContent = t(key);
  $('text').setAttribute('aria-label', t('output'));
  const result = await sendWithPromise('aegisCaptureTakeImage');
  const isOCR = result.ocr === true;
  const title = t(isOCR ? 'recognize' : 'screenshot');
  document.title = title;
  $('title').textContent = title;
  if (!result.image) { status(result.large ? 'large' : 'unavailable'); return; }
  source.src = 'data:image/png;base64,' + result.image;
  await source.decode();
  $('preview').hidden = false;
  $('actions').hidden = false;
  $('copy').hidden = isOCR;
  $('save').hidden = isOCR;
  $('share').hidden = isOCR || !navigator.share;
  $('ocr').hidden = !isOCR;
  addEvents();
  resize();
  if (isOCR) {
    void localRecognition();
    void refreshRemoteAvailability();
    window.addEventListener('focus', refreshRemoteAvailability);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) void refreshRemoteAvailability();
    });
  }
}

startPreview().catch(() => status('unavailable'));
