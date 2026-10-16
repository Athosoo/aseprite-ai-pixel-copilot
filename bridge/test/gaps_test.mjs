// 测试：做不到的需求落盘（GapLog）
//
// 覆盖：
//   1) 追加 + 生成给人看的 markdown（结构、路径、条数）
//   2) 同一条重复出现只加计数，不刷屏（归一化：大小写/标点/空白差异算同一条）
//   3) 自动兜底的关键词判断（哪些错误算"做不到"）
//   4) 长度截断 + 条目上限（最久没出现的先淘汰）
//   5) 写不进去不抛错（返回 false，桥照常跑）

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { GapLog, looksLikeCapabilityGap } from '../src/gaps.mjs';

const tmp = () => mkdtempSync(join(tmpdir(), 'aipc-gaps-'));
const cleanup = (d) => { try { rmSync(d, { recursive: true, force: true }); } catch { /* 无视 */ } };
const fixedNow = () => new Date('2026-10-15T23:40:00Z');
const newLog = (d) => new GapLog({ file: join(d, 'gaps.md'), now: fixedNow });

test('G1 记一条：返回 added/count/id/file，并写出 markdown + json', () => {
  const d = tmp();
  const g = newLog(d);
  const r = g.add({
    request: '把按钮放进 Aseprite 底部状态栏',
    why: '脚本没有往主窗口状态栏加控件的 API',
    workaround: '放在自己面板的输入行里',
    tool: 'capabilities',
    model: 'deepseek-chat',
    context: '把贴边按钮放到底部白条右侧',
  });
  assert.equal(r.ok, true);
  assert.equal(r.added, true);
  assert.equal(r.count, 1);
  assert.equal(r.id, 1);

  const md = readFileSync(join(d, 'gaps.md'), 'utf8');
  assert.match(md, /# 助手做不到的需求（自动记录）/);
  assert.match(md, /## 待处理/);
  assert.match(md, /## 已处理/);
  assert.match(md, /### 1\. 把按钮放进 Aseprite 底部状态栏/);
  assert.match(md, /做不到的原因：脚本没有往主窗口状态栏加控件的 API/);
  assert.match(md, /现在的变通：放在自己面板的输入行里/);
  assert.match(md, /待处理：\*\*1\*\* 条/);
  assert.match(md, /2026-10-15 23:40/);

  assert.equal(existsSync(join(d, 'gaps.md.json')), true);
  cleanup(d);
});

test('G2 同一条重复提：只加计数，不新增条目', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: '把配色合并到 64 色以内', why: '没有自动减色工具' });
  const r2 = g.add({ request: '把配色合并到 64 色以内。', why: '没有自动减色工具！' });
  assert.equal(r2.added, false, '标点/大小写差异要认成同一条');
  assert.equal(r2.count, 2);
  assert.equal(g.stats().entries, 1);
  assert.equal(g.stats().mentions, 2);

  const md = readFileSync(join(d, 'gaps.md'), 'utf8');
  assert.match(md, /x2/);
  assert.equal((md.match(/### /g) || []).length, 1, '只有一个小标题');
  cleanup(d);
});

test('G3 没给 request：拒绝，不写文件', () => {
  const d = tmp();
  const g = newLog(d);
  const r = g.add({ why: '只有原因' });
  assert.equal(r.ok, false);
  assert.match(r.error, /request/);
  assert.equal(existsSync(join(d, 'gaps.md')), false);
  cleanup(d);
});

test('G4 自动兜底的关键词判断', () => {
  const yes = [
    'unknown op quantize; available ops: replace_color',
    'unknown tool: draw_pixels',
    'this is not supported by the current build',
    'only 32-bit RGB/RGBA layers are supported',
    "can't do that yet",
    'no such command',
    '这件事我做不到',
    '不支持透明图层',
  ];
  const no = [
    'the region is out of bounds',
    'ops is empty',
    'invalid colour #GGGGGG',
    'the layer has no cel',
    '',
    null,
  ];
  for (const t of yes) assert.equal(looksLikeCapabilityGap(t), true, `应判为做不到: ${t}`);
  for (const t of no) assert.equal(looksLikeCapabilityGap(t), false, `不该判为做不到: ${t}`);
});

test('G5 超长字段被截断（挡住整段对话被灌进来）', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: 'r'.repeat(2000), why: 'w'.repeat(2000), context: 'c'.repeat(2000) });
  const md = readFileSync(join(d, 'gaps.md'), 'utf8');
  assert.ok(md.length < 3000, `文档不该被长文撑爆，实际 ${md.length}`);
  assert.match(md, /…/);
  cleanup(d);
});

test('G6 条目上限：满了淘汰最久没出现的', () => {
  const d = tmp();
  let tick = 0;
  const g = new GapLog({ file: join(d, 'gaps.md'), maxEntries: 3, now: () => new Date(2026, 0, 1, 0, tick++) });
  g.entries = [];
  for (let i = 0; i < 3; i++, tick++) g.add({ request: `需求${i}`, why: 'x' });
  // 前两条又被提到一次（时间更新），然后插第 4 条
  g.add({ request: '需求0', why: 'x' });
  g.add({ request: '需求1', why: 'x' });
  g.add({ request: '需求新', why: 'x' });
  const kept = g.entries.map((e) => e.request);
  assert.equal(g.entries.length <= 3, true, `不该超过上限：${kept.join(',')}`);
  assert.equal(kept.includes('需求新'), true);
  assert.equal(kept.includes('需求2'), false, '最久没出现的（需求2）该被淘汰');
  cleanup(d);
});

test('G7 写不进去也不抛错（只返回 false，桥照常跑）', () => {
  const d = tmp();
  const g = newLog(d);
  g.file = 'Q:/definitely/not/here/gaps.md';
  const r = g.add({ request: 'x', why: 'y' });
  assert.equal(r.ok, true, '内存里记下来了');
  assert.equal(g.stats().entries, 1);
  cleanup(d);
});

test('G8 机器可读的那份能读回来（重启桥不丢）', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: 'A', why: 'why-A', source: 'auto', tool: 'apply_ops' });
  g.add({ request: 'B', why: 'why-B' });

  const again = newLog(d);
  assert.equal(again.stats().entries, 2);
  assert.equal(again.entries[0].request, 'A');
  assert.equal(again.entries[0].source, 'auto');
  assert.equal(again.entries[1].why, 'why-B');
  cleanup(d);
});

test('G9 stats / recent 给面板用', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: '一', why: 'w' });
  g.add({ request: '二', why: 'w' });
  g.add({ request: '二', why: 'w' });
  const st = g.stats();
  assert.equal(st.entries, 2);
  assert.equal(st.mentions, 3);
  assert.match(st.file, /gaps\.md$/);
  const rec = g.recent(1);
  assert.equal(rec.length, 1);
  assert.equal(rec[0].request, '二');
  assert.equal(rec[0].count, 2);
  cleanup(d);
});

test('G10 done：从待处理移走 + 结论写进已处理段', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: '把按钮放进状态栏', why: '没有该 API' });
  g.add({ request: '小窗里也要能打字', why: '小窗没画输入行' });

  const res = g.done(1, '做不到：Aseprite 没有状态栏 API（探针实证）');
  assert.equal(res.ok, true);
  assert.equal(g.entries.length, 1);
  assert.equal(g.entries[0].request, '小窗里也要能打字');

  const md = readFileSync(join(d, 'gaps.md'), 'utf8');
  const resolved = md.slice(md.indexOf('## 已处理'));
  assert.match(resolved, /把按钮放进状态栏/);
  assert.match(resolved, /做不到：Aseprite 没有状态栏 API（探针实证）/);
  assert.equal(md.slice(0, md.indexOf('## 已处理')).includes('把按钮放进状态栏'), false,
    '结论要搬走，不能再留在待处理里');
  cleanup(d);
});

test('G11 手写的"已处理"结论不会被后来的记录冲掉（关键：否则开发者的结论会丢）', () => {
  const d = tmp();
  const file = join(d, 'gaps.md');
  const g = newLog(d);
  g.add({ request: 'A', why: 'w' });

  // 模拟开发者手改：在已处理段写一行
  const md = readFileSync(file, 'utf8');
  writeFileSync(file, md.replace(/（开发者在这里写结论[^）]*）/, '- 手写结论：这件事 v9.9.9 已支持'),
    'utf8');

  // 之后助手又记了一条新的
  g.add({ request: 'B', why: 'w2' });
  const after = readFileSync(file, 'utf8');
  assert.match(after, /手写结论：这件事 v9.9.9 已支持/, '手写结论必须保留');
  assert.match(after, /### 2\. B/, '新条目要追加');
  cleanup(d);
});

test('G12 done 不存在的 id：拒绝，不动文件', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: 'A', why: 'w' });
  const res = g.done(99, 'x');
  assert.equal(res.ok, false);
  assert.match(res.error, /#99/);
  assert.equal(g.entries.length, 1);
  cleanup(d);
});

test('G13 markdown 里写清楚"开发者怎么处理"（工作流自解释）', () => {
  const d = tmp();
  const g = newLog(d);
  g.add({ request: 'x', why: 'y' });
  const md = readFileSync(join(d, 'gaps.md'), 'utf8');
  assert.match(md, /给开发者/, '要写明这份文档给谁看');
  assert.match(md, /已处理/, '要有已处理段让开发者写结论');
  assert.match(md, /gaps\.mjs list/, '要写明开发者用什么命令看清单');
  cleanup(d);
});
