// Copyright 2026 GCSA

import type {PageHandlerInterface} from './aegis_agent.mojom-webui.js';
import {
  PageCallbackRouter,
  PageHandlerFactory,
  PageHandlerRemote,
} from './aegis_agent.mojom-webui.js';

export class BrowserProxy {
  readonly callbackRouter = new PageCallbackRouter();
  readonly handler: PageHandlerInterface = new PageHandlerRemote();

  constructor() {
    PageHandlerFactory.getRemote().createPageHandler(
        this.callbackRouter.$.bindNewPipeAndPassRemote(),
        (this.handler as PageHandlerRemote).$.bindNewPipeAndPassReceiver());
  }

  static getInstance(): BrowserProxy {
    return instance || (instance = new BrowserProxy());
  }
}

let instance: BrowserProxy|null = null;
