// tools.mjs 分发的单元测试：验证参数有没有正确转发到 Lua 侧。
//
//   cd bridge && node test/tools_test.mjs
//
// 这层最容易出的错是"工具名和消息类型对不上"或"字段名写错"，
// 而它们不会在 Lua 单测里暴露（Lua 侧只认自己那套字段名）。

import { TOOLS, makeDispatcher } from '../src/tools.mjs';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + extra : '')); }
};

const calls = [];
const fakeSession = {
  async request(kind, payload) { calls.push({ kind, payload }); return { ok: true, echoed: kind }; },
};
const fakeBank = { remember: (a) => ({ ok: true, bank: a }), search: (a) => ({ ok: true, search: a }) };
const fakeMemory = { remember: (a) => ({ ok: true, mem: a }), recall: (a) => ({ ok: true, rec: a }), forget: (a) => ({ ok: true, forget: a }) };

const dispatch = makeDispatcher({
  session: fakeSession, bank: fakeBank, memory: fakeMemory, cfg: {}, bundlePath: '',
});

const last = () => calls[calls.length - 1];

console.log('== 工具注册 ==');
{
  const names = TOOLS.map((t) => t.function.name);
  const want = ['canvas_info', 'apply_ops', 'crop', 'scale', 'canvas_size', 'perfect_pixel',
                'snapshot', 'rollback', 'list_versions',
                'remember', 'recall', 'forget', 'remember_color', 'search_colors'];
  for (const n of want) ok(names.includes(n), `注册了 ${n}`);
  ok(names.length === want.length, `工具总数 = ${want.length}，实际 ${names.length}`);
  // 每个工具都得有合法 schema，否则 OpenAI 侧会直接拒
  for (const t of TOOLS) {
    const f = t.function;
    ok(t.type === 'function' && f && f.name && f.description && f.parameters,
       `${f?.name} 的 schema 完整`);
  }
}

console.log('== crop 转发 ==');
{
  calls.length = 0;
  await dispatch('crop', { x: 1, y: 2, w: 30, h: 40, label: 'trim' });
  ok(last().kind === 'crop', '消息类型 = crop，实际 ' + last().kind);
  const p = last().payload;
  ok(p.x === 1 && p.y === 2 && p.w === 30 && p.h === 40, '四个坐标字段原样转发，实际 ' + JSON.stringify(p));
  ok(p.label === 'trim', 'label 转发');
}

console.log('== scale 转发（含默认 label）==');
{
  calls.length = 0;
  await dispatch('scale', { width: 32, height: 32, method: 'nearest' });
  ok(last().kind === 'scale', '消息类型 = scale');
  const p = last().payload;
  ok(p.width === 32 && p.height === 32, '宽高转发');
  ok(p.method === 'nearest', 'method 转发');
  ok(typeof p.label === 'string' && p.label.includes('32'), '没给 label 时自动生成，实际 ' + p.label);
}

console.log('== canvas_size 转发 ==');
{
  calls.length = 0;
  await dispatch('canvas_size', { width: 64, height: 64, anchor: 'center' });
  ok(last().kind === 'canvas_size', '消息类型 = canvas_size');
  ok(last().payload.anchor === 'center', 'anchor 转发');
}

console.log('== 记忆类工具走 memory，不走 session ==');
{
  calls.length = 0;
  const r1 = await dispatch('remember', { kind: 'style', text: '描边 1px' });
  ok(calls.length === 0, 'remember 没往 Lua 侧发消息');
  ok(r1.mem && r1.mem.text === '描边 1px', 'remember 转给了 memory');

  const r2 = await dispatch('recall', { query: '描边' });
  ok(r2.rec && r2.rec.query === '描边', 'recall 转给了 memory');

  const r3 = await dispatch('forget', { id: 'm123' });
  ok(r3.forget && r3.forget.id === 'm123', 'forget 转给了 memory');
}

console.log('== 旧色值工具仍然可用（向后兼容）==');
{
  const r = await dispatch('remember_color', { hex: '#FF0000', scene: 'x' });
  ok(r.bank && r.bank.hex === '#FF0000', 'remember_color 转给了 bank');
  const s = await dispatch('search_colors', { query: 'x' });
  ok(s.search !== undefined, 'search_colors 转给了 bank');
}

console.log('== 未知工具 ==');
{
  const r = await dispatch('nope', {});
  ok(typeof r.error === 'string' && r.error.includes('unknown'), '返回 unknown tool 错误');
}

console.log('== 参数校验 ==');
{
  const r = await dispatch('apply_ops', { ops: [] });
  ok(r.error !== undefined, '空 ops 被拒绝');
}

console.log(`\n==== tools_test: ${pass} 通过, ${fail} 失败 ====`);
process.exit(fail === 0 ? 0 : 1);
