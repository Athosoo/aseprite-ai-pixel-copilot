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

// 风格库的替身：只实现 dispatcher 真正会碰的那几个方法
const STYLES = {
  'pixel-icon': { name: 'pixel-icon', label: '像素图标', size: [16, 16], palette: ['#1B1B1B', '#2E86DE'], layers: ['主体', '高光'] },
  stardew: { name: 'stardew', label: '星露谷风', size: [16, 32], palette: ['#3A2412'], layers: ['阴影', '主体'] },
};
const fakeStyles = {
  names: () => Object.keys(STYLES).sort(),
  get: (n) => STYLES[n] || null,
  save: (n, spec) => ({ ok: true, name: n, saved: spec }),
};

let activeStyle = '';
const dispatch = makeDispatcher({
  session: fakeSession, bank: fakeBank, memory: fakeMemory, styles: fakeStyles, cfg: {}, bundlePath: '',
  getActiveStyle: () => activeStyle,
  setActiveStyle: (n) => { activeStyle = n; },
});

const last = () => calls[calls.length - 1];

console.log('== 工具注册 ==');
{
  const names = TOOLS.map((t) => t.function.name);
  const want = ['canvas_info', 'apply_ops', 'crop', 'scale', 'canvas_size',
                'style_list', 'style_use', 'style_save',
                'new_sprite', 'add_layer', 'draw_art',
                'perfect_pixel', 'snapshot', 'rollback', 'list_versions',
                'remember', 'recall', 'forget', 'remember_color', 'search_colors'];
  for (const n of want) ok(names.includes(n), `注册了 ${n}`);
  ok(names.length === want.length, `工具总数 = ${want.length}，实际 ${names.length}`);
  ok(new Set(names).size === names.length, '工具名没有重复');
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

console.log('== 风格工具 ==');
{
  const l = await dispatch('style_list', {});
  ok(l.styles.length === 2, '列出 2 个风格，实际 ' + l.styles.length);
  ok(l.active === null, '没选风格时 active 为 null');
  ok(l.styles[0].size === undefined || typeof l.styles[0].size === 'string', '尺寸渲染成字符串或 null');

  const u = await dispatch('style_use', { name: 'pixel-icon' });
  ok(u.ok === true, 'style_use 成功');
  ok(activeStyle === 'pixel-icon', '当前风格被记住，实际 ' + activeStyle);
  ok(u.active === 'pixel-icon', '返回里带上当前风格');

  const bad = await dispatch('style_use', { name: 'nope' });
  ok(typeof bad.error === 'string', '不存在的风格 -> 报错');
  ok(Array.isArray(bad.available) && bad.available.length === 2, '报错时给出可选列表');
  ok(activeStyle === 'pixel-icon', '失败时不改当前风格');

  const clr = await dispatch('style_use', { name: '' });
  ok(activeStyle === '', '空名字 = 清除风格');
  ok(clr.active === null, '清除后 active 为 null');

  const sv = await dispatch('style_save', { name: 'my-style', palette: ['#FFFFFF'] });
  ok(sv.ok === true && sv.name === 'my-style', 'style_save 转给了 styles.save');
  ok(calls.length === 0, '风格类工具不走 Lua 侧');
}

console.log('== 作画工具转发 ==');
{
  calls.length = 0;
  await dispatch('new_sprite', { width: 32, height: 32, colorMode: 'rgb' });
  ok(last().kind === 'new_sprite', '消息类型 = new_sprite');
  ok(last().payload.width === 32 && last().payload.height === 32, '宽高转发');

  await dispatch('add_layer', { name: '高光', opacity: 128 });
  ok(last().kind === 'add_layer', '消息类型 = add_layer');
  ok(last().payload.name === '高光' && last().payload.opacity === 128, '名字和不透明度转发');

  calls.length = 0;
  await dispatch('draw_art', {
    layer: '主体', palette: { '.': '', X: '#2E86DE' }, rows: ['X.X', '.X.'], x: 1, y: 2,
  });
  ok(last().kind === 'draw_art', '消息类型 = draw_art');
  const p = last().payload;
  ok(p.layer === '主体' && p.x === 1 && p.y === 2, '图层和偏移转发');
  ok(Array.isArray(p.rows) && p.rows.length === 2, 'rows 原样转发');
  ok(typeof p.label === 'string' && p.label.includes('3x2'), '没给 label 时按网格尺寸生成，实际 ' + p.label);
}

console.log('== draw_art 的桥侧校验（省一次 Lua 往返）==');
{
  const r1 = await dispatch('draw_art', { rows: [], palette: {} });
  ok(typeof r1.error === 'string' && r1.error.includes('rows'), '空 rows 被挡');

  const r2 = await dispatch('draw_art', { rows: ['XXX', 'XX'], palette: { X: '#FF0000' } });
  ok(typeof r2.error === 'string' && r2.error.includes('row 2'), '行宽不一致被挡，且指出了是第 2 行');

  const r3 = await dispatch('draw_art', { rows: ['XY'], palette: { X: '#FF0000' } });
  ok(typeof r3.error === 'string' && r3.error.includes('Y'), '有字符没进调色板被挡');
  ok(typeof r3.hint === 'string', '附带怎么改的提示');

  // "." 和空格不需要进调色板
  calls.length = 0;
  const r4 = await dispatch('draw_art', { rows: ['X. '], palette: { X: '#FF0000' } });
  ok(r4.error === undefined, '. 和空格不要求有调色板条目');
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
