// evolution.mjs 的单元测试：arch §6 的五条护栏逐条断言。
//
//   cd bridge && node test/evolution_test.mjs
//
// 这个文件就是「模型能修改自己」这件事的真伪判据：
// 五条护栏任一没有断言，这个能力就等于没护栏的远程执行。

import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createEvolution } from '../src/evolution.mjs';
import { createJournal } from '../src/journal.mjs';
import { createRegistry } from '../src/registry.mjs';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + JSON.stringify(extra) : '')); }
};

const ROOTS = [];
function makeEvo(opts) {
  const o = opts || {};
  const base = mkdtempSync(join(tmpdir(), 'evo-'));
  ROOTS.push(base);
  const dirs = { packs: join(base, 'packs'), staging: join(base, '.staging'), snap: join(base, '.snapshots') };
  mkdirSync(dirs.packs, { recursive: true });
  const journalFile = join(base, 'journal.jsonl');
  const journal = createJournal({ file: journalFile });
  const registry = o.registry || createRegistry({ journal: journal.log });
  const evo = createEvolution({
    registry,
    journal: journal.log,
    packsDir: dirs.packs,
    stagingDir: dirs.staging,
    snapDir: dirs.snap,
    verifyTimeoutMs: o.verifyTimeoutMs || 4000,
    maxProposes: o.maxProposes || 50,   // 护栏 5 单独用 3 测，其余段落别被预算卡住
  });
  const changed = [];
  evo.setChangedHandler((e) => changed.push(e));
  return { base, dirs, journal, journalFile, registry, evo, changed };
}

function manifestFor(id, ops, api) {
  return JSON.stringify({
    id: id, name: id, version: '1.0.0', api: api === undefined ? 1 : api,
    permissions: [], views: [], commands: [],
    ops: (ops || []).map((n) => ({ name: n })),
    requires: ['core'],
  }, null, 2);
}

function toolsSrc(entries) {
  const rows = entries.map((e) =>
    '    { name: ' + JSON.stringify(e.name) + ', description: ' + JSON.stringify('demo ' + e.name) +
    ', inputSchema: { type: "object", properties: {}, required: [] }, async run() { return { v: ' + JSON.stringify(e.value) + ' }; } },');
  return 'export default {\n  tools: [\n' + rows.join('\n') + '\n  ],\n};\n';
}

const GOOD_TESTS = "export default [\n  { name: 'unit', async run(t) { t.eq(1 + 1, 2, 'math'); t.ok(true, 'flag'); } },\n];\n";

function packFiles(id, opts) {
  const o = opts || {};
  const tools = o.tools || null;
  const names = tools ? tools.map((t) => t.name) : [];
  const files = {};
  files['manifest.json'] = manifestFor(id, o.ops === undefined ? names : o.ops, o.api);
  if (tools) files['bridge/tools.mjs'] = toolsSrc(tools);
  if (o.tests !== 'none') files['bridge/tests.mjs'] = o.tests || GOOD_TESTS;
  if (o.extra) for (const k of Object.keys(o.extra)) files[k] = o.extra[k];
  return files;
}

const snapCount = (dirs, id) => {
  const d = join(dirs.snap, id);
  return existsSync(d) ? readdirSync(d).length : 0;
};

console.log('== 护栏 1：不可写内核（路径白名单）==');
{
  const w = makeEvo();
  let r = w.evo.propose({ id: 'evil-pack', files: Object.assign(packFiles('evil-pack'), { '../../src/server.mjs': 'pwned' }) });
  ok(!!r.error && /escapes the staging dir/.test(r.error), '相对路径 .. 越界被拒，实际 ' + JSON.stringify(r.error));
  ok(!existsSync(join(w.base, 'src', 'server.mjs')), '越界写没有落到任何地方');

  r = w.evo.propose({ id: 'evil-pack', files: Object.assign(packFiles('evil-pack'), { 'C:/Windows/Temp/evil.mjs': 'pwned' }) });
  ok(!!r.error && /absolute paths are not writable/.test(r.error), 'Windows 盘符绝对路径被拒，实际 ' + JSON.stringify(r.error));

  r = w.evo.propose({ id: 'evil-pack', files: Object.assign(packFiles('evil-pack'), { '/etc/passwd': 'pwned' }) });
  ok(!!r.error && /absolute paths are not writable/.test(r.error), 'POSIX 绝对路径被拒，实际 ' + JSON.stringify(r.error));

  r = w.evo.propose({ id: 'evil-pack', files: Object.assign(packFiles('evil-pack'), { 'a/../../b.mjs': 'pwned' }) });
  ok(!!r.error && /escapes the staging dir/.test(r.error), '藏在中间段的 .. 也被拒，实际 ' + JSON.stringify(r.error));

  ok(!existsSync(join(w.dirs.staging, 'evil-pack')) || readdirSync(join(w.dirs.staging, 'evil-pack')).filter((n) => n === 'b.mjs').length === 0,
    '被拒的提议一个字节都没落盘');

  // 白名单里的正常路径当然要能写，否则护栏就成了断路
  const good = w.evo.propose({ id: 'good-pack', files: packFiles('good-pack', { tools: [{ name: 'good_tool', value: 1 }] }) });
  ok(!!good.staged && existsSync(join(good.staged, 'manifest.json')), '白名单内的 manifest 正常写入');
  ok(!!good.staged && existsSync(join(good.staged, 'bridge', 'tools.mjs')), '白名单内的 bridge/tools.mjs 正常写入');
  ok(String(good.staged).startsWith(w.dirs.staging), 'staged 路径就在 staging 目录里');

  const badVerify = await w.evo.verify({ staged: w.dirs.packs });
  ok(badVerify.ok === false && /escapes the staging dir/.test(badVerify.error), 'verify 只认 staging 里的目录（不能验任意路径）');
  const badVerify2 = await w.evo.verify({ staged: 'C:/Windows' });
  ok(badVerify2.ok === false, 'verify 拒绝绝对路径');
}

console.log('== 护栏 2：必须自测（tests.mjs 存在且断言数 > 0）==');
{
  const w = makeEvo();
  let r = w.evo.propose({ id: 'no-test', files: packFiles('no-test', { tools: [{ name: 't1', value: 1 }], tests: 'none' }) });
  let v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === false, '没有 tests.mjs 不通过');
  ok(/tests\.mjs missing/.test(v.error), '原因写明缺 tests.mjs，实际 ' + JSON.stringify(v.error));

  r = w.evo.propose({ id: 'zero-assert', files: packFiles('zero-assert', { tools: [{ name: 't2', value: 1 }], tests: "export default [ { name: 'nothing', async run(t) {} } ];\n" }) });
  v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === false, '0 断言不通过');
  ok(v.asserts === 0, '断言数如实体现在报告里，实际 ' + v.asserts);
  ok(/assertion/.test(v.error), '原因写明断言数不足，实际 ' + JSON.stringify(v.error));

  r = w.evo.propose({ id: 'fail-assert', files: packFiles('fail-assert', { tools: [{ name: 't3', value: 1 }], tests: "export default [ { name: 'bad', async run(t) { t.ok(false, 'nope'); } } ];\n" }) });
  v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === false && v.results.some((x) => !x.ok), '断言失败不通过');

  r = w.evo.propose({ id: 'real-test', files: packFiles('real-test', { tools: [{ name: 't4', value: 1 }] }) });
  v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === true, '有断言且通过 => 验过，实际 ' + JSON.stringify(v.error));
  ok(v.asserts === 2, '断言条数 = 2，实际 ' + v.asserts);
}

console.log('== 护栏 2b：verify 跑在子进程里（死循环杀得掉）==');
{
  const w = makeEvo({ verifyTimeoutMs: 1200 });
  const pidFile = join(w.base, 'child.pid');
  const spin = "import { writeFileSync } from 'node:fs';\n" +
    "export default [ { name: 'pid', async run(t) { writeFileSync(" + JSON.stringify(pidFile) + ", String(process.pid)); t.ok(true, 'wrote pid'); while (true) {} } } ];\n";
  const r = w.evo.propose({ id: 'spinner', files: packFiles('spinner', { tools: [{ name: 'spin_tool', value: 1 }], tests: spin }) });
  const t0 = Date.now();
  const v = await w.evo.verify({ staged: r.staged });
  const spent = Date.now() - t0;
  ok(v.ok === false, '死循环的 tests.mjs 不通过');
  ok(spent < 8000, '硬超时把子进程杀了（耗时 ' + spent + 'ms，没有把测试挂死）');
  ok(/timeout/.test(v.error), '原因写明超时，实际 ' + JSON.stringify(v.error));

  const childPid = readFileSync(pidFile, 'utf8').trim();
  ok(childPid !== String(process.pid), '测试代码跑在另一个进程里（pid ' + childPid + ' != ' + process.pid + '）');
}

console.log('== 护栏 3：必须同名（manifest.ops 必须真实可调用）==');
{
  const w = makeEvo();
  let r = w.evo.propose({ id: 'ghost-pack', files: packFiles('ghost-pack', { tools: [{ name: 'real_tool', value: 1 }], ops: ['ghost_tool'] }) });
  let v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === false, '声明了不存在的 op 不通过');
  ok(/ghost_tool/.test(v.error), '原因点名是哪个 op 找不到，实际 ' + JSON.stringify(v.error));

  r = w.evo.propose({ id: 'real-pack', files: packFiles('real-pack', { tools: [{ name: 'real_tool', value: 1 }], ops: ['real_tool'] }) });
  v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === true, '同名且真实导出 => 通过，实际 ' + JSON.stringify(v.error));
  ok(v.rules.some((x) => x.rule === 'same-name' && x.ok), '同名规则的通过状态被如实报告');

  // 改进内置：ops 指向注册表里已有的工具也算同名（模型可以换掉内置实现而不动内核）
  w.registry.define({ name: 'canvas_info', description: 'd', inputSchema: { type: 'object', properties: {}, required: [] }, run: async () => ({ ok: true }) });
  r = w.evo.propose({ id: 'shadow-pack', files: packFiles('shadow-pack', { ops: ['canvas_info'] }) });
  v = await w.evo.verify({ staged: r.staged });
  ok(v.ok === true, '声明改进内置工具（注册表里已有）也通过，实际 ' + JSON.stringify(v.error));
}

console.log('== 护栏 4：必须可回滚（快照 / 自动回退 / 只留最近 3 版）==');
{
  const w = makeEvo();
  const staged = async (id, value) => {
    const r = w.evo.propose({ id: id, files: packFiles(id, { tools: [{ name: id + '_tool', value: value }] }) });
    const v = await w.evo.verify({ staged: r.staged });
    if (!v.ok) throw new Error('setup verify failed: ' + v.error);
    return r.staged;
  };

  const s1 = await staged('roll-pack', 1);
  const a1 = await w.evo.activate({ staged: s1 });
  ok(!a1.error && a1.id === 'roll-pack', '第一版激活成功，实际 ' + JSON.stringify(a1.error || a1.id));
  ok(a1.previous === null, '首次安装没有上一版，previous 为 null');
  ok((await w.registry.get('roll-pack_tool').run({}, {})).v === 1, '激活后注册表立刻可调用（热装载，不重启）');
  ok(w.changed.some((c) => c.id === 'roll-pack' && c.action === 'activate'), '激活后推了 pack.changed');

  const s2 = await staged('roll-pack', 2);
  const a2 = await w.evo.activate({ staged: s2 });
  ok(!a2.error && typeof a2.previous === 'string', '第二版激活时自动快照了上一版');
  ok(snapCount(w.dirs, 'roll-pack') === 1, '快照目录里有 1 版，实际 ' + snapCount(w.dirs, 'roll-pack'));
  ok((await w.registry.get('roll-pack_tool').run({}, {})).v === 2, '第二版实现生效');

  const rb = await w.evo.rollback({ id: 'roll-pack' });
  ok(rb.ok === true, '回滚成功，实际 ' + JSON.stringify(rb.error));
  ok((await w.registry.get('roll-pack_tool').run({}, {})).v === 1, '回滚后实现回到第一版');
  ok(w.changed.some((c) => c.id === 'roll-pack' && c.action === 'rollback'), '回滚后推了 pack.changed');

  const rb2 = await w.evo.rollback({ id: 'roll-pack' });
  ok(rb2.ok === false, '没有快照时回滚如实失败，实际 ' + JSON.stringify(rb2.error));

  // 只留最近 3 版：连推 5 版，快照数不能超过 3
  for (let i = 3; i <= 7; i++) await w.evo.activate({ staged: await staged('roll-pack', i) });
  const n = snapCount(w.dirs, 'roll-pack');
  ok(n <= 3, '快照最多保留 3 版，实际 ' + n);
  ok(n === 3, '满了之后就稳定在 3，实际 ' + n);

  // 装上去但装载失败 => 自动回退到快照
  const before = readFileSync(join(w.dirs.packs, 'roll-pack', 'bridge', 'tools.mjs'), 'utf8');
  const sBad = await staged('roll-pack', 99);
  writeFileSync(join(sBad, 'bridge', 'tools.mjs'), 'export default { tools: [ ', 'utf8');   // 验证之后磁盘被改坏
  const aBad = await w.evo.activate({ staged: sBad });
  ok(!!aBad.error, '装载失败时 activate 报错，实际 ' + JSON.stringify(aBad.error && aBad.error.slice(0, 60)));
  ok(typeof aBad.rolledBackTo === 'string', '报错里带自动回退到的快照路径');
  const after = readFileSync(join(w.dirs.packs, 'roll-pack', 'bridge', 'tools.mjs'), 'utf8');
  ok(after === before, '自动回退把上一版文件原样还原了');
  ok(typeof (await w.registry.get('roll-pack_tool').run({}, {})) === 'object', '回退后工具仍然可调用');
}

console.log('== 护栏 4b：没验过不许激活 ==');
{
  const w = makeEvo();
  const r = w.evo.propose({ id: 'unverified', files: packFiles('unverified', { tools: [{ name: 'unv_tool', value: 1 }] }) });
  const a = await w.evo.activate({ staged: r.staged });
  ok(!!a.error && /verify/.test(a.error), '跳过 verify 直接 activate 被拒，实际 ' + JSON.stringify(a.error));
  ok(!existsSync(join(w.dirs.packs, 'unverified')), '被拒的激活没有写进 packs 目录');

  const r2 = w.evo.propose({ id: 'unverified', files: packFiles('unverified', { tools: [{ name: 'unv_tool', value: 1 }] }) });
  await w.evo.verify({ staged: r2.staged });
  const a2 = await w.evo.activate({ staged: r2.staged });
  ok(!a2.error, '验过之后就能激活');
  const a3 = await w.evo.activate({ staged: r2.staged });
  ok(!!a3.error && /verify/.test(a3.error), '同一份 staged 不能重复激活（verify 结果一次性）');
}

console.log('== 护栏 5：预算（单轮 3 次 propose / 200 行 / 32KB）==');
{
  const w = makeEvo({ maxProposes: 3 });
  for (let i = 1; i <= 3; i++) {
    const r = w.evo.propose({ id: 'budget-' + i, files: packFiles('budget-' + i, { tools: [{ name: 'b_tool_' + i, value: i }] }) });
    ok(!r.error, '第 ' + i + ' 次 propose 通过，实际 ' + JSON.stringify(r.error));
  }
  ok(w.evo.budgetLeft() === 0, '三次之后预算归零，实际 ' + w.evo.budgetLeft());
  const over = w.evo.propose({ id: 'budget-4', files: packFiles('budget-4', { tools: [{ name: 'b_tool_4', value: 4 }] }) });
  ok(!!over.error && /budget/.test(over.error), '第 4 次 propose 被拒，实际 ' + JSON.stringify(over.error));
  ok(over.budgetLeft === 0, '拒绝里带上剩余预算');
  w.evo.resetTurn();
  ok(w.evo.budgetLeft() === 3, '新一轮预算重置为 3');
  const again = w.evo.propose({ id: 'budget-5', files: packFiles('budget-5', { tools: [{ name: 'b_tool_5', value: 5 }] }) });
  ok(!again.error, '重置后又能提了');

  const longTests = 'export default [\n  { name: ' + "'x'" + ', async run(t) { t.ok(true, ' + "'y'" + '); } },\n];\n' + '// pad\n'.repeat(220);
  const big = w.evo.propose({ id: 'huge-lines', files: packFiles('huge-lines', { tools: [{ name: 'big_tool', value: 1 }], tests: longTests }) });
  ok(!!big.error && /lines/.test(big.error), '超过 200 行被拒，实际 ' + JSON.stringify(big.error));

  const fat = w.evo.propose({ id: 'huge-bytes', files: packFiles('huge-bytes', { tools: [{ name: 'fat_tool', value: 1 }], extra: { 'bridge/notes.md': 'x'.repeat(33 * 1024) } }) });
  ok(!!fat.error && /bytes/.test(fat.error), '超过 32KB 被拒，实际 ' + JSON.stringify(fat.error));

  const d1 = w.evo.propose({ id: 'digest-a', files: packFiles('digest-a', { tools: [{ name: 'd_tool', value: 1 }] }) });
  const d2 = w.evo.propose({ id: 'digest-a', files: packFiles('digest-a', { tools: [{ name: 'd_tool', value: 1 }] }) });
  ok(!!d1.digest && d1.digest === d2.digest, '同样的文件 => 同样的 digest（可重复）');
  ok(d1.staged === d2.staged, '同样的 digest => 同一个 staging 目录（不重复占盘）');
}

console.log('== pack_health 的数据来源与自动回滚 ==');
{
  const w = makeEvo();
  ok(Object.keys(w.evo.health()).length === 0, '还没调用就没有健康记录');
  w.evo.record('p1', 10, true);
  w.evo.record('p1', 20, false);
  const h = w.evo.health().p1;
  ok(h.calls === 2 && h.fails === 1, 'calls/fails 如实累计，实际 ' + JSON.stringify(h));
  ok(h.msAvg === 15, 'msAvg 是均值，实际 ' + h.msAvg);
  w.evo.record('', 5, false);
  ok(Object.keys(w.evo.health()).length === 1, '没有 pack 的调用不记账');

  // 失败率超阈值 => 自动回滚（arch §6 的闭环回路）
  const r1 = w.evo.propose({ id: 'sick-pack', files: packFiles('sick-pack', { tools: [{ name: 'sick_tool', value: 1 }] }) });
  await w.evo.verify({ staged: r1.staged });
  await w.evo.activate({ staged: r1.staged });
  const r2 = w.evo.propose({ id: 'sick-pack', files: packFiles('sick-pack', { tools: [{ name: 'sick_tool', value: 2 }] }) });
  await w.evo.verify({ staged: r2.staged });
  await w.evo.activate({ staged: r2.staged });
  for (let i = 0; i < 5; i++) w.evo.record('sick-pack', 100, i > 0 ? false : true);
  const rolled = await w.evo.healthCheck();
  ok(rolled.length === 1 && rolled[0].id === 'sick-pack', '失败率超阈值的包被自动回滚，实际 ' + JSON.stringify(rolled));
  ok((await w.registry.get('sick_tool').run({}, {})).v === 1, '自动回滚后实现退回上一版');
}

console.log('== journal 账本 ==');
{
  const w = makeEvo();
  // 两版：第一版装上，第二版激活时才会产生快照，rollback 才有东西可回
  for (const v of [1, 2]) {
    const r = w.evo.propose({ id: 'log-pack', files: packFiles('log-pack', { tools: [{ name: 'log_tool', value: v }] }) });
    await w.evo.verify({ staged: r.staged });
    await w.evo.activate({ staged: r.staged });
  }
  const rb = await w.evo.rollback({ id: 'log-pack' });
  ok(rb.ok === true, '回滚本身成功（这是下面账本断言的前提）');
  const kinds = readFileSync(w.journalFile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l).kind);
  for (const k of ['evolution.propose', 'evolution.verify', 'evolution.activate', 'evolution.rollback']) {
    ok(kinds.includes(k), '账本记下了 ' + k);
  }
  ok(kinds.includes('evolution.rollback'), '回滚也留痕（出事能复盘）');
}

console.log('== propose 参数校验 ==');
{
  const w = makeEvo();
  ok(!!w.evo.propose({}).error, '空参数被拒');
  ok(!!w.evo.propose({ id: 'BadId', files: packFiles('BadId') }).error, '大写 id 被拒');
  ok(!!w.evo.propose({ id: 'ok-id', files: {} }).error, '空 files 被拒');
  ok(!!w.evo.propose({ id: 'ok-id', files: { 'x.mjs': 'x' } }).error, '没有 manifest.json 被拒');
  ok(!!w.evo.propose({ id: 'ok-id', files: { 'manifest.json': '{not json' } }).error, 'manifest 不是 JSON 被拒');
  const api99 = w.evo.propose({ id: 'ok-id', files: packFiles('ok-id', { api: 99 }) });
  ok(!!api99.error && /api/.test(api99.error), 'api 版本不符被拒，实际 ' + JSON.stringify(api99.error));
  const wrongId = w.evo.propose({ id: 'ok-id', files: packFiles('other-id') });
  ok(!!wrongId.error && /manifest.id/.test(wrongId.error), 'id 与 manifest.id 不一致被拒，实际 ' + JSON.stringify(wrongId.error));
  ok(!!w.evo.propose({ id: 'a', files: packFiles('a') }).error, 'id 太短被拒');
}

for (const r of ROOTS) { try { rmSync(r, { recursive: true, force: true }); } catch { /* 无视 */ } }

console.log('\n==== evolution_test: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
