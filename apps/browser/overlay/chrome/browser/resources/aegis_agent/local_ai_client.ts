// Copyright 2026 GCSA
// 每次任务独占 Worker；取消或离开页面会终止推理并释放模型。
import {getTrustedScriptURL} from '//resources/js/static_types.js';
export interface LocalAiResult {
  ready?: boolean;
  update?: boolean;
  statuses?: Array<{id: string, ready: boolean, update: boolean}>;
  translations?: string[];
  language?: string;
  minim?: Array<{index: number, sensitivity: number, necessity: number, recommendation: string}>;
  phishlang?: {score: number, windows: number, tokens: number, flagged: boolean};
}
export class LocalAiClient {
  private worker: Worker|null = null;
  private reject: ((error: Error) => void)|null = null;
  private timer = 0;
  private downloadJob = '';
  cancel(reason = 'cancelled') {
    window.clearTimeout(this.timer);
    if (this.downloadJob) {
      void fetch('./local_ai/cancel/' + this.downloadJob, {credentials: 'omit', keepalive: true}).catch(() => {});
      this.downloadJob = '';
    }
    this.worker?.terminate();
    this.worker = null;
    this.reject?.(new Error(reason));
    this.reject = null;
  }
  async run(request: Record<string, unknown>, progress: (text: string) => void): Promise<LocalAiResult> {
    this.cancel();
    return new Promise((resolve, reject) => {
      this.reject = reject;
      const worker = new Worker(getTrustedScriptURL`./local_ai/worker.js` as string, {type: 'module'});
      this.worker = worker;
      this.downloadJob = request['op'] === 'download' ? crypto.randomUUID() : '';
      const timer = window.setTimeout(() => {
        if (this.worker === worker) this.cancel('runtime_timeout');
      }, request['op'] === 'download' ? 1800000 : 180000);
      this.timer = timer;
      const finish = () => {
        window.clearTimeout(timer);
        worker.terminate();
        if (this.worker === worker) { this.worker = null; this.reject = null; this.downloadJob = ''; }
      };
      worker.onmessage = ({data}: MessageEvent<{progress?: string, error?: string, result?: LocalAiResult}>) => {
        if (this.worker !== worker) return;
        if (data.progress) { progress(data.progress); return; }
        finish();
        if (data.error || !data.result) reject(new Error(data.error || 'invalid_result'));
        else resolve(data.result);
      };
      worker.onerror = () => {
        if (this.worker !== worker) return;
        finish(); reject(new Error('runtime_unavailable'));
      };
      worker.postMessage({...request, downloadJob: this.downloadJob});
    });
  }
}
