/** 从 lib/ops.lua 的 ops.manifest() 生成 lib/ops.manifest.json。
 *  ops.lua 是唯一真源：改了算子/参数就重跑这个脚本，别手改 JSON。
 *
 *  跑法： node test/gen-manifest.mjs          # 生成/覆盖
 *         node test/gen-manifest.mjs --check  # 只校验是否过期（过期 exit 1）
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { loadConfig, luaRoot } from '../lib/config.js';
import { computeManifest } from './manifest-lua.mjs';
import assert from 'node:assert';

const ROOT = luaRoot();
const OPS = join(ROOT, 'lib', 'ops.lua');
const MANIFEST_PATH = join(ROOT, 'lib', 'ops.manifest.json');
const CHECK = process.argv.includes('--check');

assert.ok(existsSync(OPS), 'missing domain layer: ' + OPS);

const cfg = loadConfig({ luaRoot: ROOT });
const manifest = await computeManifest(cfg);

// 契约：清单必须自解释（下游工具说明直接拿它生成）
for (const e of manifest) {
  assert.ok(e.name && typeof e.name === 'string', 'op without name');
  assert.ok(e.desc && typeof e.desc === 'string', e.name + ': missing desc');
  assert.ok(Array.isArray(e.params) && e.params.length > 0, e.name + ': missing params');
  for (const p of e.params) {
    assert.ok(p.name && p.type, e.name + ': param without name/type');
    assert.ok(typeof p.desc === 'string' && p.desc.length > 0, e.name + '.' + p.name + ': missing desc');
  }
}

const json = JSON.stringify(manifest, null, 2) + '\n';
const current = existsSync(MANIFEST_PATH) ? readFileSync(MANIFEST_PATH, 'utf8') : '';

if (CHECK) {
  const same = current === json;
  console.log((same ? 'ok: manifest is up to date' : 'stale: run node test/gen-manifest.mjs') +
    ' (' + manifest.length + ' ops)');
  if (!same) process.exit(1);
} else {
  writeFileSync(MANIFEST_PATH, json, 'utf8');
  console.log('manifest: ' + manifest.length + ' ops, ' +
    manifest.reduce((n, e) => n + e.params.length, 0) + ' params');
  console.log('wrote ' + MANIFEST_PATH);
}
