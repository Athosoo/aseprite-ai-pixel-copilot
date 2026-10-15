// 测试：对话历史的持久化 + 压缩（上下文管理）
//
// 覆盖四件事：
//   1) 落盘 / 读回 / 损坏文件不炸
//   2) 压缩的触发条件与"摘要进提示词"
//   3) 摘要失败时绝不丢原文（宁可涨 token）
//   4) 被中断留下的半截 tool_calls 组不会把历史写坏

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { Conversation } from '../src/history.mjs';

const tmp = () => mkdtempSync(join(tmpdir(), 'aipc-hist-'));
const cleanup = (d) => { try { rmSync(d, { recursive: true, force: true }); } catch { /* 无视 */ } };

const user = (t) => ({ role: 'user', content: t });
const ai = (t) => ({ role: 'assistant', content: t });
const tool = (t, id = 'c1') => ({ role: 'tool', tool_call_id: id, content: t });
const calls = (ids) => ({
  role: 'assistant',
  content: '',
  tool_calls: ids.map((id) => ({ id, type: 'function', function: { name: 'canvas_info', arguments: '{}' } })),
});

test('H1 新建：没文件也不炸，初始为空', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'sub', 'history.json') });
  assert.equal(c.messages.length, 0);
  assert.equal(c.summary, '');
  assert.equal(c.stats().messages, 0);
  assert.equal(c.stats().tokens, 0);
  assert.equal(c.stats().budgetTokens, 16000, '默认预算 16k token');
  cleanup(d);
});

test('H2 落盘再读回：消息和摘要都在（重启不丢记忆）', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  const a = new Conversation({ file });
  a.push(user('把背景换成 #2E86DE'));
  a.push(ai('done: 12 pixels'));
  a.summary = 's1';
  assert.equal(a.save(), true);

  const b = new Conversation({ file });
  assert.equal(b.messages.length, 2);
  assert.equal(b.messages[0].content, '把背景换成 #2E86DE');
  assert.equal(b.summary, 's1');
  cleanup(d);
});

test('H3 文件损坏 / 不是 JSON：当新会话，别让桥起不来', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  writeFileSync(file, '{ this is not json', 'utf8');
  const c = new Conversation({ file });
  assert.equal(c.messages.length, 0);

  writeFileSync(file, '[]', 'utf8');            // 合法 JSON 但不是我们要的形状
  const c2 = new Conversation({ file });
  assert.equal(c2.messages.length, 0);
  cleanup(d);
});

test('H4 toMessages：系统提示在前，摘要紧随其后，历史原样接上', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json') });
  c.push(user('你好'));
  assert.equal(c.toMessages('SYS').length, 2);   // 没摘要就只有 system + 历史

  c.summary = '我们决定了用 #2E86DE';
  const msgs = c.toMessages('SYS');
  assert.equal(msgs[0].role, 'system');
  assert.equal(msgs[0].content, 'SYS');
  assert.equal(msgs[1].role, 'system');
  assert.match(msgs[1].content, /Earlier conversation summary/);
  assert.match(msgs[1].content, /#2E86DE/);
  assert.equal(msgs[2].content, '你好');
  cleanup(d);
});

test('H5 summaryBlock：没摘要时返回空串（不白占 token）', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json') });
  assert.equal(c.summaryBlock(), '');
  c.summary = 'X';
  assert.equal(c.summaryBlock().includes('X'), true);
  cleanup(d);
});

test('H6 压缩阈值按 token 算：短消息不触发，长了才触发', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 1000 });
  for (let i = 0; i < 20; i++) c.push(user('短'));
  assert.equal(c.needsCompaction(), false, '20 条短消息 = 约 20 token，远没到 1000');

  c.push(ai('长'.repeat(3000)));           // 3000 字 ≈ 1200 token
  assert.equal(c.needsCompaction(), true);
  cleanup(d);
});

test('H6b 条数安全阀：工具调用刷屏时按条数兜底', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 200000, maxMessages: 5 });
  for (let i = 0; i < 5; i++) c.push(tool('{}'));
  assert.equal(c.needsCompaction(), false);
  c.push(tool('{}'));
  assert.equal(c.needsCompaction(), true, '预算还没到，但条数超了');
  cleanup(d);
});

test('H7 压缩：老的交给摘要，最近一段原文留着，摘要写进提示词', async () => {
  const d = tmp();
  const file = join(d, 'history.json');
  // 预算 1000 token，保留比例 0.4 -> 保留约 400 token（160 字左右），至少 2 条
  const c = new Conversation({ file, budgetTokens: 1000, minKeep: 2, keepRatio: 0.4 });
  // 三轮"用户 -> 调工具 -> 结果"，每轮约 190 token
  for (let i = 0; i < 3; i++) {
    c.push(user(`第${i + 1}句` + '说明'.repeat(50)));
    c.push(calls([`a${i}`]));
    c.push(tool('r'.repeat(300), `a${i}`));
  }
  c.push(ai('很长的回答'.repeat(300)));      // 1500 字 ≈ 600 token，把预算顶爆

  const before = c.usedTokens();
  assert.equal(c.needsCompaction(), true);
  let seen = '';
  const rep = await c.compact(async (text) => { seen = text; return 'SUMMARY-1'; });
  assert.equal(rep.compacted, true);
  assert.equal(rep.tokensBefore, before);
  assert.match(seen, /第1句/, '老的对话要进摘要');
  assert.ok(c.messages.length < 10, '老消息被搬走了');
  assert.ok(c.usedTokens() < before, '压缩后必须更小');
  assert.equal(c.summary, 'SUMMARY-1');
  assert.match(c.summaryBlock(), /SUMMARY-1/);

  // 压缩后立刻落盘：重启后摘要还在
  assert.equal(existsSync(file), true);
  const back = new Conversation({ file });
  assert.equal(back.summary, 'SUMMARY-1');
  assert.ok(back.messages.length < 10);
  cleanup(d);
});

test('H7b 切分不切开工具调用组：不会留下孤立的 tool 结果', async () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 1000, minKeep: 1, keepRatio: 0.1 });
  c.push(user('老消息'.repeat(600)));       // 720 token
  c.push(calls(['a1']));
  c.push(tool('r'.repeat(900), 'a1'));
  c.push(user('最新'));
  assert.equal(c.needsCompaction(), true);
  const rep = await c.compact(async () => 'S');
  assert.equal(rep.compacted, true);
  const first = c.messages[0];
  assert.notEqual(first.role, 'tool', '保留段不能以孤立 tool 结果开头');
  cleanup(d);
});

test('H8 摘要失败：原文一条都不丢（宁可涨 token，也不失忆）', async () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 1000 });
  c.push(user('重要决定：外壳用 #2E86DE'));
  c.push(ai('好的'));
  c.push(user('继续' + '长'.repeat(4000)));

  const n = c.messages.length;
  const rep = await c.compact(async () => { throw new Error('LLM down'); });
  assert.equal(rep.compacted, false);
  assert.match(rep.reason, /LLM down/);
  assert.equal(c.messages.length, n, '失败时必须原样留着');
  assert.equal(c.summary, '');

  const empty = await c.compact(async () => '   ');
  assert.equal(empty.compacted, false, '返回空白等于没摘要');
  assert.equal(c.messages.length, n);
  cleanup(d);
});

test('H9 纯工具噪音：不用麻烦 LLM，直接丢', async () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 1000, minKeep: 1 });
  c.push(tool('x'.repeat(3000)));        // 3000 字 ≈ 1200 token，单条就超预算
  c.push(tool('{"painted":64}'));
  c.push(user('最新一句'));

  let called = false;
  const rep = await c.compact(async () => { called = true; return 'x'; });
  assert.equal(rep.compacted, true);
  assert.equal(rep.reason, 'tool-noise-only');
  assert.equal(called, false);
  assert.equal(c.messages.length, 1);
  assert.equal(c.messages[0].content, '最新一句');
  cleanup(d);
});

test('H9b 预算没到就不动：compact 是幂等的空操作', async () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 100000 });
  c.push(user('小对话'));
  const rep = await c.compact(async () => { throw new Error('不该被调到'); });
  assert.equal(rep.compacted, false);
  assert.equal(rep.reason, 'under-budget');
  assert.equal(c.messages.length, 1);
  cleanup(d);
});

test('H10 摘要本身也有上限：多次压缩不会越滚越长', async () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json'), budgetTokens: 1000, minKeep: 1, keepRatio: 0.1 });
  for (let round = 0; round < 8; round++) {
    c.push(user('u'.repeat(3000)));
    await c.compact(async () => 'Z'.repeat(1000));
  }
  assert.ok(c.summary.length <= 3600, `summary 长度 ${c.summary.length} 应该有上限`);
  cleanup(d);
});

test('H10b 预算可被外部改（设置面板改完立刻生效）', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json') });
  c.push(ai('x'.repeat(20000)));            // 约 8000 token
  assert.equal(c.needsCompaction(), false);
  c.budgetTokens = 4000;
  assert.equal(c.needsCompaction(), true, '调小预算后下一次检查就该压缩');
  c.budgetTokens = 200000;
  assert.equal(c.needsCompaction(), false);
  cleanup(d);
});

test('H11 半截 tool_calls 组：落盘时被丢掉，完整的那组留着', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  const c = new Conversation({ file });

  c.messages = [user('画个图标'), calls(['a1']), tool('{"ok":1}', 'a1'), calls(['b1'])];
  c.save();
  assert.equal(c.messages.length, 3, '末尾没结果的那次调用要丢掉');
  assert.equal(c.messages[2].tool_call_id, 'a1');

  // 完整的一组：一个字节都不要动
  c.messages = [user('画个图标'), calls(['a1']), tool('{"ok":1}', 'a1')];
  c.save();
  assert.equal(c.messages.length, 3);

  // 孤立的 tool 结果（前面没有 assistant）也要丢掉
  c.messages = [user('x'), tool('{"ok":1}', 'a9')];
  c.save();
  assert.equal(c.messages.length, 1);
  cleanup(d);
});

test('H12 组里只回了一半结果：整组丢，别留半截给 API 报 400', () => {
  const d = tmp();
  const c = new Conversation({ file: join(d, 'history.json') });
  c.messages = [user('x'), calls(['a1', 'a2']), tool('{"ok":1}', 'a1')];
  c.save();
  assert.equal(c.messages.length, 1, 'a2 没结果 -> assistant(tool_calls) 也不能留');
  assert.equal(c.messages[0].content, 'x');
  cleanup(d);
});

test('H13 reset：历史清空 + 落盘，重启也不复活', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  const c = new Conversation({ file });
  c.push(user('secret'));
  c.summary = 'SUM';
  c.save();

  const rep = c.reset();
  assert.equal(rep.messages, 0);
  assert.equal(c.messages.length, 0);
  assert.equal(c.summary, '');
  assert.equal(c.summaryBlock(), '');

  const back = new Conversation({ file });
  assert.equal(back.messages.length, 0);
  assert.equal(back.summary, '');
  cleanup(d);
});

test('H14 落盘写不进去时（目录只读）不抛错，只返回 false', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  const c = new Conversation({ file });
  c.push(user('x'));
  // 用一个不可能创建的路径（盘符不存在）逼 writeFileSync 失败
  c.file = 'Q:/definitely/not/here/history.json';
  assert.equal(c.save(), false);
  cleanup(d);
});

test('H15 落盘内容可读且不含函数/循环引用', () => {
  const d = tmp();
  const file = join(d, 'history.json');
  const c = new Conversation({ file });
  c.push(user('hi'));
  c.push(calls(['a1']));
  c.push(tool('{"x":1}', 'a1'));
  c.save();
  const raw = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(raw.messages.length, 3);
  assert.equal(raw.messages[1].tool_calls[0].function.name, 'canvas_info');
  cleanup(d);
});
