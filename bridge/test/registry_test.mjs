// registry.mjs 的单元测试：define / 同 id 覆盖 / remove / fingerprint 变更语义。
//
//   cd bridge && node test/registry_test.mjs
//
// 注册表是三层结构里唯一的"能力清单真相"，所以这里钉的是语义而不是实现：
// 覆盖要能换实现但保住来源，指纹要在 schema 变时变、实现体变时不变。

import { createRegistry } from '../src/registry.mjs';
import { createJournal } from '../src/journal.mjs';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + extra : '')); }
};

const dir = mkdtempSync(join(tmpdir(), 'reg-'));
const jfile = join(dir, 'journal.jsonl');
const journal = createJournal({ file: jfile });
const spec = (name, extra = {}) => ({
  name,
  description: 'does ' + name,
  inputSchema: { type: 'object', properties: { a: { type: 'string' } }, required: [] },
  run: async () => ({ ok: true, from: name }),
  ...extra,
});

console.log('== define / get / list ==');
{
  const reg = createRegistry({ journal: journal.log });
  const a = reg.define(spec('alpha'));
  ok(a.name === 'alpha', 'define 返回注册项');
  ok(reg.get('alpha') === a, 'get 拿到的就是同一个对象');
  ok(reg.get('nope') === null, '没定义的返回 null');
  reg.define(spec('beta'));
  ok(reg.size() === 2, 'size = 2，实际 ' + reg.size());
  ok(reg.list().map((s) => s.name).join(',') === 'alpha,beta', 'list 保持定义顺序（工具的发送顺序靠它）');
  ok(typeof reg.get('alpha').run === 'function', 'run 被保留');
  ok(reg.get('alpha').pack === 'builtin', '没写 pack 默认 builtin');
}

console.log('== 非法 spec 被挡住 ==');
{
  const reg = createRegistry({});
  const bad = (fn, label) => {
    try { fn(); ok(false, label + '（居然没抛）'); } catch { ok(true, label); }
  };
  bad(() => reg.define(null), 'define(null) 抛 TypeError');
  bad(() => reg.define({ run: () => 1 }), '没有 name 抛 TypeError');
  bad(() => reg.define({ name: 'x' }), '没有 run 抛 TypeError');
  bad(() => reg.define({ name: 'x', run: 'not a function' }), 'run 不是函数抛 TypeError');
  ok(reg.size() === 0, '被拒的 spec 不会进表');
}

console.log('== 同 id 覆盖 ==');
{
  const reg = createRegistry({ journal: journal.log });
  reg.define(spec('gamma', { pack: 'user-x', meta: { since: 'v1' } }));
  const newer = reg.define(spec('gamma', { pack: 'user-y', run: async () => ({ ok: true, v: 2 }) }));
  ok(reg.size() === 1, '覆盖不新增条目');
  ok(newer.pack === 'user-y', '后定义的包赢');
  ok(newer.run && (await newer.run()) .v === 2, '实现换成新的');
  ok(newer.meta.since === 'v1', 'since 保留第一次的值（才知道这工具从哪来）');
  ok(newer.meta.evolved === true, 'evolved 标记被覆盖过');
  const fresh = reg.define(spec('delta'));
  ok(fresh.meta.evolved === false, '首次定义不是 evolved');
}

console.log('== remove ==');
{
  const reg = createRegistry({ journal: journal.log });
  reg.define(spec('eps'));
  ok(reg.remove('eps') === true, '删掉存在的返回 true');
  ok(reg.get('eps') === null, '删完就查不到');
  ok(reg.remove('eps') === false, '再删返回 false');
  ok(reg.size() === 0, 'size 归零');
}

console.log('== fingerprint 变更语义 ==');
{
  const reg = createRegistry({ journal: journal.log });
  reg.define(spec('t1'));
  const f1 = reg.fingerprint();
  ok(typeof f1 === 'string' && f1.length === 40, '指纹是 sha1 十六进制');

  reg.define(spec('t1'));
  ok(reg.fingerprint() === f1, '同名同 schema 重定义，指纹不变（这样才不会每次都重发 schema）');

  // 懒构造的语义：实现体换了但签名没变 => 指纹必须不变，否则每轮都在重发工具表
  reg.define(spec('t1', { run: async () => ({ ok: true, v: 2 }) }));
  ok(reg.fingerprint() === f1, '只换实现体，指纹不变');

  reg.define(spec('t1', { description: 'does t1, better' }));
  const fDesc = reg.fingerprint();
  ok(fDesc !== f1, '说明文字变了，指纹跟着变（模型看到的东西变了）');

  reg.define(spec('t1', { inputSchema: { type: 'object', properties: { b: { type: 'integer' } }, required: [] } }));
  const f2 = reg.fingerprint();
  ok(f2 !== fDesc, 'schema 变了，指纹跟着变');

  reg.define(spec('t2'));
  const f3 = reg.fingerprint();
  ok(f3 !== f2, '加一个工具，指纹变');

  reg.remove('t2');
  ok(reg.fingerprint() === f2, '删掉刚加的，指纹回到之前那版');

  reg.define(spec('t1', { pack: 'user-z' }));
  ok(reg.fingerprint() !== f2, 'pack 换了也算变（来源变了）');
}

console.log('== expose / journal ==');
{
  const reg = createRegistry({ journal: journal.log });
  reg.define(spec('hidden', { expose: false }));
  ok(reg.get('hidden').expose === false, 'expose:false 被保留（内核自用条目）');
  ok(reg.get('hidden').run !== undefined, 'expose:false 依然可派发');

  journal.log({ kind: 'marker' });
  const lines = readFileSync(jfile, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const kinds = lines.map((l) => l.kind);
  ok(kinds.includes('registry.define'), 'define 记账');
  ok(kinds.includes('registry.override'), '覆盖记账（override）');
  ok(kinds.includes('registry.remove'), 'remove 记账');
  const ov = lines.find((l) => l.kind === 'registry.override');
  ok(ov && ov.name === 'gamma', '记账带工具名，实际 ' + JSON.stringify(ov && ov.name));
}

console.log('== 账本不可用时不拖垮注册 ==');
{
  const reg = createRegistry({ journal: () => { throw new Error('disk on fire'); } });
  let threw = false;
  try { reg.define(spec('survivor')); } catch { threw = true; }
  ok(!threw, '账本抛异常也不影响 define');
  ok(reg.get('survivor') !== null, '条目照样进表');
}

try { rmSync(dir, { recursive: true, force: true }); } catch { /* 无视 */ }

console.log(`\n==== registry_test: ${pass} 通过, ${fail} 失败 ====`);
if (fail > 0) process.exit(1);
