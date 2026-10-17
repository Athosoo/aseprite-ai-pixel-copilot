// packs.mjs 的单元测试：动态 import + cache-busting 到底有没有生效。
//
//   cd bridge && node test/packs_test.mjs
//
// 这个文件存在的唯一理由：Node 会缓存 ESM 模块，少写 ?v= 时"文件改了但实现没变"
// 依然会让热重载看起来成功。所以这里同时断言两件事 ——
// 同 URL 再 import 拿到的确实是旧的（缓存真的存在），而 loadPacks 拿到的是新的。

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

import { createRegistry } from '../src/registry.mjs';
import { loadPacks } from '../src/packs.mjs';
import { PACK_DIRS, MODEL_TOOLS, TOOLS, buildCapabilities } from '../src/tools.mjs';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + JSON.stringify(extra) : '')); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const TMP = mkdtempSync(join(tmpdir(), 'packs-'));

function toolSrc(name, value) {
  return `export default {
  tools: [
    {
      name: '${name}',
      description: 'demo tool ${name}',
      inputSchema: { type: 'object', properties: {}, required: [] },
      async run() { return { v: ${JSON.stringify(value)} }; },
    },
  ],
};
`;
}

// where: 'bridge' = packs/<id>/bridge/tools.mjs（§4 冻结布局），'root' = 包根（§2 桥侧布局）
function writePack(root, id, { tools = [], toolsSrc = '', manifest = null, where = 'bridge', skipTools = false } = {}) {
  const dir = join(root, id);
  const modDir = where === 'bridge' ? join(dir, 'bridge') : dir;
  mkdirSync(modDir, { recursive: true });
  const mf = manifest || {
    id, name: id, version: '1.0.0', api: 1,
    permissions: [], views: [], commands: [],
    ops: tools.map((n) => ({ name: n })), requires: ['core'],
  };
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(mf, null, 2), 'utf8');
  if (!skipTools) writeFileSync(join(modDir, 'tools.mjs'), toolsSrc, 'utf8');
  return dir;
}

console.log('== 内置包聚合 ==');
{
  ok(TOOLS.length === 25, 'TOOLS 还是 25 个内置工具，实际 ' + TOOLS.length);
  ok(TOOLS.every((t) => t.type === 'function' && t.function && t.function.name && t.function.description && t.function.parameters),
    'TOOLS 每个元素的形状与 v0.5.x 一致（type/function.name/description/parameters）');
  ok(TOOLS.map((t) => t.function.name).join(',') === [
    'canvas_info', 'apply_ops', 'crop', 'scale', 'canvas_size',
    'style_list', 'style_use', 'style_save', 'ask_user', 'log_gap', 'capabilities',
    'open_document', 'list_workspace', 'new_sprite', 'add_layer', 'draw_art',
    'perfect_pixel', 'snapshot', 'rollback', 'list_versions',
    'remember', 'recall', 'forget', 'remember_color', 'search_colors',
  ].join(','), 'TOOLS 的顺序与 v0.5.x 逐项一致（发货顺序不抖动）');

  const names = MODEL_TOOLS.map((t) => t.function.name);
  ok(names.length === 31, 'MODEL_TOOLS = 25 内置 + 6 自扩展，实际 ' + names.length);
  for (const n of ['list_capabilities', 'propose_pack', 'verify_pack', 'activate_pack', 'rollback_pack', 'pack_health']) {
    ok(names.includes(n), 'MODEL_TOOLS 里有 ' + n);
  }
  ok(!names.includes('gaps_info'), 'gaps_info 是 expose:false，不进模型清单');
}

console.log('== 自扩展能力对模型可见（can.evolve）==');
{
  // 模型问「你能做什么」时必须看得见自扩展手柄，否则它不知道自己能改自己；
  // 但又不能并进 can.tools —— 那条线的长度被旧测试钉在 25。
  const cap = buildCapabilities({ info: { ops: [] } }, {});
  const builtinNames = new Set(TOOLS.map((t) => t.function.name));
  const expected = MODEL_TOOLS.map((t) => t.function.name).filter((n) => !builtinNames.has(n));

  ok(Array.isArray(cap.can.evolve) && cap.can.evolve.length === 6, 'can.evolve 恰好 6 个手柄，实际 ' + JSON.stringify((cap.can.evolve || []).length));
  ok(cap.can.evolve.map((e) => e.name).sort().join(',') === expected.sort().join(','),
    'can.evolve 的名字 = MODEL_TOOLS 里非内置的那 6 个，实际 ' + JSON.stringify(cap.can.evolve.map((e) => e.name)));
  ok(cap.can.evolve.every((e) => typeof e.name === 'string' && typeof e.description === 'string' && e.description.length > 0),
    '每个手柄都带一句说明（模型据此判断该调哪个）');
  ok(TOOLS.length === 25, '加了 can.evolve 之后 TOOLS 长度仍是 25，实际 ' + TOOLS.length);
  const toolKeys = Object.keys(cap.can.tools);
  ok(toolKeys.length === 25 && toolKeys.every((n) => builtinNames.has(n)),
    'can.tools 的长度与内容没被新字段带偏（' + toolKeys.length + ' 条，全是内置工具）');
  ok(cap.can.evolve.every((e) => !builtinNames.has(e.name)), 'can.evolve 与 can.tools 没有重叠');
}

console.log('== 内置包目录能被装载器读出来 ==');
{
  const reg = createRegistry({});
  const rep = await loadPacks({ dirs: [PACK_DIRS.root], registry: reg });
  ok(rep.errors.length === 0, '内置包零错误，实际 ' + JSON.stringify(rep.errors));
  ok(rep.loaded.length === 9, '内置包 9 个（8 能力包 + 自扩展手柄），实际 ' + rep.loaded.length);
  const canvas = rep.loaded.find((p) => p.id === 'builtin-canvas');
  ok(canvas && canvas.tools.length === 5, 'PackInfo.tools 列出包内工具');
  ok(canvas && typeof canvas.dir === 'string' && canvas.version === '1.0.0', 'PackInfo 带 dir/version');
  ok(canvas && typeof canvas.stamp === 'string' && canvas.stamp.length > 0, 'PackInfo 带 mtime stamp（热重载的判据）');
  ok(reg.get('canvas_info').pack === 'builtin-canvas', '注册项记着自己的来源包');
}

console.log('== cache-busting：改文件后实现真的变了 ==');
{
  const root = join(TMP, 'hot');
  mkdirSync(root, { recursive: true });
  writePack(root, 'hot-pack', { tools: ['hot_tool'], toolsSrc: toolSrc('hot_tool', 1) });

  const reg = createRegistry({});
  const first = await loadPacks({ dirs: [root], registry: reg });
  const v1 = await reg.get('hot_tool').run({}, {});
  ok(v1.v === 1, '第一次装载拿到 v1');
  const fp1 = reg.fingerprint();
  const stamp1 = first.loaded[0].stamp;

  // 对照组：模块缓存是真的存在 —— 同 URL 再 import，拿回来的还是旧实现。
  // 没有这一条，下面那条"验到了新实现"就不能证明是 cache-busting 起的作用。
  const plainUrl = pathToFileURL(join(root, 'hot-pack', 'bridge', 'tools.mjs')).href;
  const plain1 = await import(plainUrl);
  writePack(root, 'hot-pack', { tools: ['hot_tool'], toolsSrc: toolSrc('hot_tool', 2) });
  await sleep(20);   // mtime 精度兜底：同毫秒内改两次，靠 size 变化也能区分
  const plain2 = await import(plainUrl);
  ok((await plain1.default.tools[0].run({}, {})).v === 1, '对照组：同 URL 的旧模块仍是 v1');
  ok((await plain2.default.tools[0].run({}, {})).v === 1, '对照组：同 URL 再 import 命中缓存，仍是 v1（所以 ?v= 才能救）');

  const second = await loadPacks({ dirs: [root], registry: reg });
  const v2 = await reg.get('hot_tool').run({}, {});
  ok(v2.v === 2, '改文件后 loadPacks 装载到了 v2 实现（cache-busting 生效）');
  ok(second.loaded[0].stamp !== stamp1, 'stamp 跟着文件变了');
  ok(reg.fingerprint() === fp1, '只改实现体、schema 没变 => 指纹不变（懒构造，不重发工具表）');

  writePack(root, 'hot-pack', {
    tools: ['hot_tool'],
    toolsSrc: toolSrc('hot_tool', 2).replace('demo tool hot_tool', 'demo tool hot_tool, now with a longer description'),
  });
  await sleep(20);
  await loadPacks({ dirs: [root], registry: reg });
  ok(reg.fingerprint() !== fp1, '说明文字变了 => 指纹变（模型看到的东西变了）');
}

console.log('== 坏包不影响好包，且原因可读 ==');
{
  const root = join(TMP, 'mixed');
  mkdirSync(root, { recursive: true });
  writePack(root, 'good-a', { tools: ['good_tool'], toolsSrc: toolSrc('good_tool', 'ok') });
  writePack(root, 'bad-api', {
    tools: ['nope'],
    toolsSrc: toolSrc('nope', 1),
    manifest: { id: 'bad-api', name: 'x', version: '1.0.0', api: 99, permissions: [], views: [], commands: [], ops: [], requires: [] },
  });
  writePack(root, 'bad-syntax', { tools: ['broken'], toolsSrc: 'export default { tools: [ ' });
  mkdirSync(join(root, 'no-manifest', 'bridge'), { recursive: true });
  writeFileSync(join(root, 'no-manifest', 'bridge', 'tools.mjs'), 'export default { tools: [] };', 'utf8');

  const reg = createRegistry({});
  const rep = await loadPacks({ dirs: [root], registry: reg });
  ok(rep.loaded.some((p) => p.id === 'good-a'), '好包照样装上了');
  ok(reg.get('good_tool') !== null, '好包的工具照样注册');
  const eApi = rep.errors.find((e) => e.id === 'bad-api');
  ok(eApi && /api must be 1/.test(eApi.err), 'api 版本不符有可读原因，实际 ' + JSON.stringify(eApi && eApi.err));
  const eSyn = rep.errors.find((e) => e.id === 'bad-syntax');
  ok(eSyn && /failed to import/.test(eSyn.err), '语法错误有可读原因，实际 ' + JSON.stringify(eSyn && eSyn.err));
  const eNo = rep.errors.find((e) => e.id === 'no-manifest');
  ok(eNo && /manifest\.json missing/.test(eNo.err), '缺 manifest 有可读原因，实际 ' + JSON.stringify(eNo && eNo.err));
  ok(rep.errors.length === 3, '三个坏包都被如实报出来，实际 ' + rep.errors.length);
}

console.log('== 重载后消失的工具被摘掉 ==');
{
  const root = join(TMP, 'shrink');
  mkdirSync(root, { recursive: true });
  const two = `export default {
  tools: [
    { name: 'keep_me', description: 'a', inputSchema: { type: 'object', properties: {}, required: [] }, async run() { return { v: 1 }; } },
    { name: 'drop_me', description: 'b', inputSchema: { type: 'object', properties: {}, required: [] }, async run() { return { v: 2 }; } },
  ],
};
`;
  writePack(root, 'shrinker', { tools: ['keep_me', 'drop_me'], toolsSrc: two });
  const reg = createRegistry({});
  await loadPacks({ dirs: [root], registry: reg });
  ok(reg.get('drop_me') !== null, '第一版两个工具都在');
  writePack(root, 'shrinker', { tools: ['keep_me'], toolsSrc: toolSrc('keep_me', 3) });
  await sleep(20);
  await loadPacks({ dirs: [root], registry: reg });
  ok(reg.get('keep_me') !== null, '留下的工具还在');
  ok(reg.get('drop_me') === null, '删掉的工具不会变成幽灵条目');
}

console.log('== user 包覆盖内置（同 id 覆盖语义）==');
{
  const reg = createRegistry({});
  await loadPacks({ dirs: [PACK_DIRS.root], registry: reg });
  const root = join(TMP, 'override');
  mkdirSync(root, { recursive: true });
  writePack(root, 'builtin-canvas', { tools: ['canvas_info'], toolsSrc: toolSrc('canvas_info', 'from-user-pack') });
  const rep = await loadPacks({ dirs: [root], registry: reg });
  ok(rep.errors.length === 0, '覆盖包装得上，实际 ' + JSON.stringify(rep.errors));
  ok(reg.get('canvas_info').pack === 'builtin-canvas', 'pack 字段还是同一个包 id');
  const out = await reg.get('canvas_info').run({}, {});
  ok(out.v === 'from-user-pack', 'user 包换掉了内置实现（不动内核就能改进内置能力）');
  ok(reg.get('canvas_info').meta.evolved === true, '被覆盖过的工具带 evolved 标记');
}

console.log('== 边界：纯 Lua 包 / 包根布局 / 空目录 ==');
{
  const root = join(TMP, 'edge');
  mkdirSync(root, { recursive: true });
  writePack(root, 'lua-only', { skipTools: true });
  writePack(root, 'root-layout', { tools: ['root_tool'], toolsSrc: toolSrc('root_tool', 'root'), where: 'root' });
  const reg = createRegistry({});
  const rep = await loadPacks({ dirs: [root], registry: reg });
  ok(rep.errors.length === 0, '两个边界包都装上了，实际 ' + JSON.stringify(rep.errors));
  const luaOnly = rep.loaded.find((p) => p.id === 'lua-only');
  ok(luaOnly && luaOnly.tools.length === 0, '没有 tools.mjs 的纯 Lua 包不算失败（tools 为空）');
  ok(reg.get('root_tool') !== null, 'tools.mjs 放包根也认（§2 的桥侧布局）');
  const miss = await loadPacks({ dirs: [join(TMP, 'definitely-not-here')], registry: reg });
  ok(miss.loaded.length === 0 && miss.errors.length === 0, '目录不存在时安静返回，不炸');
}

try { rmSync(TMP, { recursive: true, force: true }); } catch { /* 无视 */ }

console.log(`\n==== packs_test: ${pass} 通过, ${fail} 失败 ====`);
if (fail > 0) process.exit(1);
