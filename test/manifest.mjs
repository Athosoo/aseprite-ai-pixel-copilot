/** 清单一致性：lib/ops.manifest.json 必须和 lib/ops.lua 对得上（不需要 Aseprite）。
 *  ops.lua 是唯一真源；改了算子就重跑 test/gen-manifest.mjs。 */
import { strict as assert } from 'node:assert';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const MANIFEST_PATH = join(ROOT, 'lib', 'ops.manifest.json');
const OPS_PATH = join(ROOT, 'lib', 'ops.lua');
let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); pass++; console.log('  ok   ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '   <- ' + e.message); }
}

const manifest = JSON.parse(readFileSync(MANIFEST_PATH, 'utf8'));
const opsLua = readFileSync(OPS_PATH, 'utf8');

console.log('== 真源 ==');
check('lib/ops.lua 存在（本仓库自给）', () => assert.ok(existsSync(OPS_PATH)));
check('lib/util.lua 存在（ops.lua 依赖它）', () => assert.ok(existsSync(join(ROOT, 'lib', 'util.lua'))));
check('不再有 vendor/UPSTREAM 残留', () => {
  assert.ok(!existsSync(join(ROOT, 'lib', 'vendor')));
  assert.ok(!existsSync(join(ROOT, 'lib', 'UPSTREAM.json')));
});

console.log('== 清单与源码对得上 ==');
check('清单是 10 个算子', () => assert.equal(manifest.length, 10));
check('清单按名字排序（输出稳定）', () => {
  const names = manifest.map((e) => e.name);
  assert.deepEqual(names, [...names].sort());
});
check('清单名字集合 == ops.lua 里注册的算子', () => {
  const fromSource = [...opsLua.matchAll(/^\s*([a-z_]+)\s*=\s*\{\s*fn\s*=\s*op_/gm)].map((m) => m[1]).sort();
  assert.deepEqual(fromSource, manifest.map((e) => e.name));
});
check('每个算子都有 desc 与参数', () => {
  for (const e of manifest) {
    assert.ok(e.desc && e.desc.length > 10, e.name);
    assert.ok(e.params.length > 0, e.name);
    for (const p of e.params) {
      assert.ok(p.name && p.type && p.desc, e.name + '.' + (p.name || '?'));
      assert.ok(['color', 'int', 'number', 'bool', 'object', 'region'].includes(p.type), p.type);
    }
  }
});
check('默认值与实现一致（contrast 1.3 / pivot 128 / quantize 64 / sharpen 1）', () => {
  const def = (op, name) => manifest.find((e) => e.name === op).params.find((p) => p.name === name).default;
  assert.equal(def('contrast', 'amount'), 1.3);
  assert.equal(def('contrast', 'pivot'), 128);
  assert.equal(def('quantize', 'colors'), 64);
  assert.equal(def('sharpen', 'amount'), 1);
});
check('必填参数与实现一致（replace_color.from/to、fill_region.color）', () => {
  const req = (op) => manifest.find((e) => e.name === op).params.filter((p) => p.required).map((p) => p.name);
  assert.deepEqual(req('replace_color'), ['from', 'to']);
  assert.deepEqual(req('fill_region'), ['color']);
  assert.deepEqual(req('erase_region'), ['region']);
});
check('生成脚本在（否则清单没法更新）', () => assert.ok(existsSync(join(ROOT, 'test', 'gen-manifest.mjs'))));

console.log('== 工具说明的生成 ==');
const { manifestText, applyDescription, paramSummary, STALE_HINT } = await import('../lib/opsinfo.js');
check('manifestText 一行一个算子，带 params 摘要', () => {
  const lines = manifestText(manifest).split('\n');
  assert.equal(lines.length, manifest.length);
  assert.ok(lines.every((l) => l.startsWith('- ') && l.includes('[params:')));
});
check('参数摘要格式：name:type[!][=default]', () => {
  assert.equal(paramSummary({ name: 'amount', type: 'number', default: 1.3 }), 'amount:number=1.3');
  assert.equal(paramSummary({ name: 'from', type: 'color', required: true }), 'from:color!');
});
check('applyDescription 内嵌全部算子（模型不调 aseprite_ops 也看得见）', () => {
  const d = applyDescription(manifest);
  assert.match(d, /Available operators/);
  for (const e of manifest) assert.ok(d.includes('- ' + e.name + ':'), e.name);
});
check('冲突提示提到 Revert 与 Ctrl+S', () => {
  assert.match(STALE_HINT, /Revert/);
  assert.match(STALE_HINT, /Ctrl\+S/);
});

console.log('\n==== manifest: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
