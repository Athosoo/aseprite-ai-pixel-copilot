// 测试：多对话管理（一个对话一个文件 + 迁移 + 删除进回收站）
//
// 覆盖：
//   1) 建 / 切 / 改名 / 删，以及"删最后一个"被拒
//   2) 序号与 id 两种查找（面板上敲的是序号）
//   3) 老的 data/history.json 自动变成第一个对话（幂等 + 留底）
//   4) 活动对话落盘（重启桥还认）
//   5) 坏文件只跳过它自己；留档 / 回放行的上限

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { ConversationStore, newConversationId, titleFromMessages } from '../src/conversations.mjs';
import { deriveTitle, userRequestOf } from '../src/history.mjs';

const tmp = () => mkdtempSync(join(tmpdir(), 'aipc-conv-'));
const cleanup = (d) => { try { rmSync(d, { recursive: true, force: true }); } catch { /* 无视 */ } };

const user = (t) => ({ role: 'user', content: t });
const ai = (t) => ({ role: 'assistant', content: t });

/** 固定时间 + 每次调用往后走一秒，让 updatedAt 的先后顺序确定（list 按它排） */
function clock(startIso = '2026-10-16T00:00:00.000Z') {
  let t = Date.parse(startIso);
  return () => new Date((t += 1000));
}

const newStore = (d, extra = {}) => new ConversationStore({
  dir: join(d, 'conversations'),
  budgetTokens: 16000,
  now: clock(),
  ...extra,
});

/** 聊两句，让这个对话有内容和标题 */
function chat(store, text, reply = 'ok') {
  store.current.push(user(`[Current canvas state]\n(pixels)\n\n[User request]\n${text}`));
  store.current.push(ai(reply));
  store.current.save();
}

test('C1 空目录：自动建一个对话并激活，list 只有它', () => {
  const d = tmp();
  const s = newStore(d);
  const items = s.list();
  assert.equal(items.length, 1, '至少有一个对话');
  assert.equal(items[0].active, true);
  assert.equal(items[0].id, s.activeId);
  assert.match(s.activeId, /^c-\d{8}-[a-z0-9]{4}$/, 'id 形如 c-YYYYMMDD-xxxx');
  assert.equal(s.current.messages.length, 0);
  cleanup(d);
});

test('C2 聊天后落盘：标题从第一句用户话派生（不带画布上下文）', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '把背景改成蓝色');
  assert.equal(s.current.title, '把背景改成蓝色');

  const again = newStore(d, { activeId: s.activeId });
  assert.equal(again.current.title, '把背景改成蓝色');
  assert.equal(again.current.messages.length, 2, '消息也在');
  cleanup(d);
});

test('C3 新建对话：互不串味，旧的还在', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '第一个话题');
  const firstId = s.activeId;

  const res = s.create({ title: '第二话题' });
  assert.equal(res.ok, true);
  assert.equal(res.action, 'new');
  assert.notEqual(s.activeId, firstId);
  assert.equal(s.current.messages.length, 0, '新对话是空的');
  assert.equal(s.list().length, 2);

  chat(s, '第二个话题');
  assert.equal(s.current.messages.length, 2);

  const sw = s.activate(firstId);
  assert.equal(sw.ok, true);
  assert.equal(s.activeId, firstId);
  assert.equal(s.current.messages.length, 2, '切回去还是原来那两条');
  assert.equal(s.current.messages[0].content.includes('第一个话题'), true);
  cleanup(d);
});

test('C4 切换支持序号（面板上敲的就是序号）', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, 'A');
  s.create({ title: 'B' });
  chat(s, 'B 的内容');

  const items = s.list();
  assert.equal(items.length, 2);
  const other = items[1];                       // 列表里第二个（较旧的）
  const sw = s.activate('2');
  assert.equal(sw.ok, true, '序号 2 能找到');
  assert.equal(s.activeId, other.id);
  assert.equal(s.activate('9').ok, false, '越界序号要拒绝');
  assert.equal(s.activate('nope').ok, false, '不存在的 id 要拒绝');
  cleanup(d);
});

test('C5 切到同一个对话：不改内容、返回 unchanged', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '随便');
  const res = s.activate(s.activeId);
  assert.equal(res.ok, true);
  assert.equal(res.unchanged, true);
  assert.equal(s.current.messages.length, 2);
  cleanup(d);
});

test('C6 改名：当前对话和非当前对话都能改', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '原来叫这个');
  const a = s.activeId;
  const b = s.create({ title: 'B' }).id;

  assert.equal(s.rename(a, '新名字').ok, true);
  assert.equal(s.find(a).title, '新名字');
  assert.equal(s.rename(b, '  B 改名  ').title, 'B 改名', '两端空白要清掉');
  assert.equal(s.rename(a, '   ').ok, false, '空标题要拒绝');
  assert.equal(s.rename('99', 'x').ok, false, '找不到就拒绝');
  cleanup(d);
});

test('C7 删除：文件进 trash/，不是真删', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, 'A');
  const a = s.activeId;
  const b = s.create({ title: 'B' }).id;

  const res = s.remove(a);
  assert.equal(res.ok, true);
  assert.equal(res.action, 'delete');
  assert.equal(s.list().length, 1);
  assert.equal(s.list()[0].id, b, '剩下的那个还在');
  assert.equal(s.activeId, b, '删的是当前 -> 自动切到另一个');
  assert.equal(existsSync(res.trashed), true, '回收站里能捞回来');

  const trashed = readdirSync(join(d, 'conversations', 'trash'));
  assert.equal(trashed.length, 1);
  assert.equal(JSON.parse(readFileSync(res.trashed, 'utf8')).title, 'A', '回收站里那份内容是完整的');
  cleanup(d);
});

test('C8 删当前对话时不会把文件"原地复活"', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '要被删的');
  const a = s.activeId;
  s.create({ title: '留下的' });

  const res = s.remove(a);
  assert.equal(res.ok, true);
  assert.equal(s.list().length, 1, '被删的那个不能又冒出来');
  assert.equal(s.list().some((it) => it.id === a), false);
  cleanup(d);
});

test('C9 只剩一个时拒绝删除（否则界面没地方可去）', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '唯一的一个');
  const res = s.remove(s.activeId);
  assert.equal(res.ok, false);
  assert.equal(res.reason, 'last');
  assert.equal(s.list().length, 1);
  cleanup(d);
});

test('C10 删除非当前对话：当前不动', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, 'A');
  const a = s.activeId;
  const b = s.create({ title: 'B' }).id;
  chat(s, 'B 的内容');

  const res = s.remove(a);
  assert.equal(res.ok, true);
  assert.equal(s.activeId, b, '删的不是当前，当前不该变');
  assert.equal(s.current.messages.length, 2, '当前对话内容没被冲掉');
  cleanup(d);
});

test('C11 活动对话落盘：新开 store 还认（config.json 里那个 activeConversation）', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, 'A');
  const a = s.activeId;
  const b = s.create({ title: 'B' }).id;

  const again = newStore(d, { activeId: b });
  assert.equal(again.activeId, b);
  assert.equal(again.current.title, 'B');

  const third = newStore(d, { activeId: 'c-19700101-zzzz' });   // 不存在的 id
  assert.equal(third.list().length, 2);
  assert.ok(third.activeId === a || third.activeId === b, '退回一个存在的对话，别崩');
  cleanup(d);
});

test('C12 迁移：老的 history.json 变成第一个对话，原文件留底', () => {
  const d = tmp();
  const legacy = join(d, 'history.json');
  writeFileSync(legacy, JSON.stringify({
    summary: '老摘要',
    messages: [user('[Current canvas state]\n(pixels)\n\n[User request]\n把角色改成 32x32'), ai('好的')],
  }, null, 2), 'utf8');

  const s = newStore(d, { legacyFile: legacy });
  assert.equal(s.list().length, 1, '迁出一个对话');
  assert.equal(s.current.messages.length, 2, '老消息一条不少');
  assert.equal(s.current.summary, '老摘要');
  assert.equal(s.current.title, '把角色改成 32x32');
  assert.equal(existsSync(legacy), false, '原文件已改名');
  assert.equal(existsSync(`${legacy}.migrated`), true, '留了底');
  cleanup(d);
});

test('C13 迁移是幂等的：已经有对话就不重复迁', () => {
  const d = tmp();
  const legacy = join(d, 'history.json');
  writeFileSync(legacy, JSON.stringify({ messages: [user('老话题'), ai('ok')] }), 'utf8');

  const s1 = newStore(d, { legacyFile: legacy });
  const n1 = s1.list().length;
  const s2 = newStore(d, { legacyFile: legacy });
  assert.equal(s2.list().length, n1, '第二次打开不会又多一个');
  assert.equal(n1, 1);
  cleanup(d);
});

test('C14 空的 history.json 不迁移（没必要造一个空对话）', () => {
  const d = tmp();
  const legacy = join(d, 'history.json');
  writeFileSync(legacy, JSON.stringify({ summary: '', messages: [] }), 'utf8');
  const s = newStore(d, { legacyFile: legacy });
  assert.equal(s.list().length, 1, '只有一个自动建的新对话');
  assert.equal(s.current.messages.length, 0);
  assert.equal(existsSync(`${legacy}.migrated`), false, '空文件不动它');
  cleanup(d);
});

test('C15 坏文件只跳过它自己，别的对话照常列出', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '好的那个');
  const good = s.activeId;
  writeFileSync(join(d, 'conversations', 'c-20260101-bad1.json'), '{ 不是 json', 'utf8');
  writeFileSync(join(d, 'conversations', 'readme.txt'), '不是对话', 'utf8');

  const items = s.list();
  assert.equal(items.length, 1, '坏的跳过、非 .json 忽略');
  assert.equal(items[0].id, good);
  cleanup(d);
});

test('C16 留档：压缩掉的老消息进 archive，重启还在', () => {
  const d = tmp();
  const s = newStore(d);
  for (let i = 0; i < 8; i++) chat(s, `第 ${i} 句`, 'ok');
  const before = s.current.messages.length;
  s.current._archive(s.current.messages.slice(0, 3));
  s.current.messages = s.current.messages.slice(3);
  s.current.save();

  const again = newStore(d, { activeId: s.activeId });
  assert.equal(again.current.archive.length, 3, '留档跨重启还在');
  assert.equal(again.current.messages.length, before - 3);
  assert.equal(again.current.stats().archived, 3);
  cleanup(d);
});

test('C17 留档有上限：超了丢最老的', () => {
  const d = tmp();
  const s = new ConversationStore({ dir: join(d, 'conversations'), now: clock() });
  const c = s.current;
  c.archiveCap = 5;
  for (let i = 0; i < 9; i++) c._archive([user(`m${i}`)]);
  assert.equal(c.archive.length, 5);
  assert.equal(c.archive[0].content, 'm4', '留下的是最新的那几条');
  cleanup(d);
});

test('C18 回放：pushLog 攒行、有上限、能取最近 N 行', () => {
  const d = tmp();
  const s = newStore(d);
  const c = s.current;
  c.logCap = 5;
  for (let i = 0; i < 9; i++) c.pushLog('tool', `line ${i}`);
  assert.equal(c.log.length, 5);
  assert.equal(c.log[0].text, 'line 4');

  c.pushLog('info', '有 i18n 键的一行', 'ctxRestored');
  assert.equal(c.log[c.log.length - 1].i18n, 'ctxRestored');
  c.pushLog('info', '', 'x');
  assert.equal(c.log.length, 5, '空行不记');

  const r = s.replay(3);
  assert.equal(r.lines.length, 3);
  assert.equal(r.more, 2, '告诉面板还有更早的没回放');
  assert.equal(r.lines[2].text, '有 i18n 键的一行', '取的是最近那几行');
  cleanup(d);
});

test('C19 回放跨重启：面板关掉再打开还能看到上次的记录', () => {
  const d = tmp();
  const s = newStore(d);
  s.current.pushLog('user', '画个图标');
  s.current.pushLog('tool', '已画 128 像素');
  s.current.save();

  const again = newStore(d, { activeId: s.activeId });
  const r = again.replay();
  assert.equal(r.lines.length, 2);
  assert.equal(r.lines[0].kind, 'user');
  assert.equal(r.lines[1].text, '已画 128 像素');
  cleanup(d);
});

test('C20 reset 清内容但保留 id 和标题（清空 != 删掉对话）', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, '别把我删了');
  s.current.pushLog('user', '别把我删了');
  const id = s.activeId;
  const title = s.current.title;

  s.current.reset();
  assert.equal(s.current.messages.length, 0);
  assert.equal(s.current.log.length, 0);
  assert.equal(s.current.id, id);
  assert.equal(s.current.title, title);
  assert.equal(s.list().length, 1, '对话还在');
  cleanup(d);
});

test('C21 标题派生：抠掉画布上下文、按字符截断、没用户话时兜底', () => {
  assert.equal(userRequestOf('[Current canvas state]\nxx\n\n[User request]\n把背景改蓝'), '把背景改蓝');
  assert.equal(userRequestOf('没有标记的原话'), '没有标记的原话');
  assert.equal(deriveTitle([ai('先说话'), user('[User request]\n换个风格')]), '换个风格');
  assert.equal(deriveTitle([user('[User request]\n第一行\n第二行')]), '第一行', '只取首行');
  const long = deriveTitle([user('[User request]\n' + '字'.repeat(40))]);
  assert.equal([...long].length, 25, '24 个字符 + 省略号');
  assert.equal(long.endsWith('…'), true);
  assert.equal(deriveTitle([], '兜底'), '兜底');
  assert.equal(titleFromMessages([], '新对话'), '新对话');
  cleanup(tmp());
});

test('C22 id 生成：同一天也不撞（随机尾巴）', () => {
  const now = new Date('2026-10-16T12:00:00Z');
  const ids = new Set();
  for (let i = 0; i < 50; i++) ids.add(newConversationId(now));
  assert.equal(ids.size, 50);
  for (const id of ids) assert.match(id, /^c-20261016-[a-z0-9]{4}$/);
  cleanup(tmp());
});

test('C23 stats：给面板/设置用的概览', () => {
  const d = tmp();
  const s = newStore(d);
  chat(s, 'A');
  s.create({ title: 'B' });
  const st = s.stats();
  assert.equal(st.count, 2);
  assert.equal(st.active, s.activeId);
  assert.equal(st.title, 'B');
  assert.equal(st.dir, join(d, 'conversations'));
  cleanup(d);
});
