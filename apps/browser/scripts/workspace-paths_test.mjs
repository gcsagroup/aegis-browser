import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const scripts=path.dirname(fileURLToPath(import.meta.url));

test('构建路径遵守环境变量、标记、统一默认目录的优先级',()=>{
  const fixture=fs.mkdtempSync(path.join(os.tmpdir(),'aegis-workspace-paths-'));
  try {
    const scriptDir=path.join(fixture,'apps/browser/scripts');
    fs.mkdirSync(scriptDir,{recursive:true});
    fs.copyFileSync(path.join(scripts,'common.sh'),path.join(scriptDir,'common.sh'));
    const env={...process.env};delete env.CHROMIUM_ROOT;
    const resolve=(overrides={})=>execFileSync('bash',['-c','source "$1"; printf "%s" "$CHROMIUM_ROOT"','aegis-path-test',path.join(scriptDir,'common.sh')],{env:{...env,...overrides},encoding:'utf8'});
    assert.equal(resolve(),path.join(os.homedir(),'Projects/GCSA-aegis-build/macos'));
    const marker=path.join(fixture,'apps/browser/.chromium-root');
    fs.writeFileSync(marker,'/fixture/build/macos\n');
    assert.equal(resolve(),'/fixture/build/macos');
    assert.equal(resolve({CHROMIUM_ROOT:'/fixture/build/android'}),'/fixture/build/android');
  } finally {
    // 仅回收本测试刚创建的随机临时目录；不接收外部路径。
    fs.rmSync(fixture,{recursive:true,force:true});
  }
});

test('libtorrent准备使用同一源码入口，不回退到已撤下的旧目录',()=>{
  const source=fs.readFileSync(path.join(scripts,'bootstrap-libtorrent.sh'),'utf8');
  assert.match(source,/source "\$script_dir\/common\.sh"/);
  assert.match(source,/chromium_src="\$\{GCSA_CHROMIUM_SRC:-\$CHROMIUM_ROOT\/src\}"/);
  assert.doesNotMatch(source,/GCSA-aegis-chromium\/src/);
});

test('原生运行检查与产物身份脚本的默认路径均已收敛',()=>{
  for(const file of ['verify-download-runtime.mjs','verify-cdp-runtime.mjs',
    'verify-fingerprint-runtime.mjs','write-build-identity.mjs',
    'verify-multisite-runtime.mjs','verify-miner-runtime.mjs']) {
    const source=fs.readFileSync(path.join(scripts,file),'utf8');
    assert.doesNotMatch(source,/GCSA-aegis-chromium/,file);
    assert.match(source,/GCSA-aegis-build/,file);
    execFileSync(process.execPath,['--check',path.join(scripts,file)]);
  }
});
