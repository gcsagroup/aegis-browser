// Copyright 2026 GCSA
declare module 'chrome-untrusted://aegis-agent/local_ai/catalog.js' {
export interface TranslationAsset {
  sourceLanguage: string; targetLanguage: string; fileType: string; version: string;
  decompressedSize: number; decompressedHash: string;
  attachment: {location: string; size: number; hash: string};
}
export interface LanguagePack {
  id: string; from: string; to: string; rows: TranslationAsset[];
  version: string; beamSize: number; bytes: number; installedBytes: number;
}
export interface TranslationRoute {
  id: string; from: string; to: string; packs: string[]; pivot: boolean;
}
export function normalizeLanguage(value: string): string;
export function languagePacks(rows: TranslationAsset[]): LanguagePack[];
export function translationRoutes(packs: LanguagePack[]): TranslationRoute[];
export function routePacks(rows: TranslationAsset[], direction: string): LanguagePack[];
export function detectSource(text: string): string;
}
