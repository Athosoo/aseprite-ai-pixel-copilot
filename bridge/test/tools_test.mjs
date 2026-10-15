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
                'style_list', 'style_use', 'style_save', 'ask_user', 'capabilities',
                'open_document', 'list_workspace',
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

// ---------------------------------------------------------------- P8
// 造图：scale=1 就是"已经被矫正过的"真像素画（1px 一格）
function makePixelArt(scale, logical) {
  const size = scale * logical;
  const data = new Uint8Array(size * size * 4);
  const palette = [[229, 57, 53], [46, 134, 222], [255, 224, 189], [74, 52, 40], [126, 211, 33]];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const lx = Math.floor(x / scale), ly = Math.floor(y / scale);
      const idx = ((lx - 8) ** 2 + (ly - 8) ** 2 < 36) ? ((lx + ly) % 3) + 1 : 0;
      const [r, g, b] = palette[idx];
      const o = (y * size + x) * 4;
      data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255;
    }
  }
  return data;
}

console.log('== P8 perfect_pixel 幂等：已矫正过的图不再被处理 ==');
{
  const { join } = await import('node:path');
  const bundlePath = join(process.cwd(), 'vendor', 'perfectPixel.mjs');
  const imports = [];
  const says = [];
  const sess = {
    upload: { buf: makePixelArt(1, 16), w: 16, h: 16, name: 'already.ase' },
    turnProcessed: new Set(),
    async request() { return { ok: true }; },
    sendImport(d, w, h) { imports.push({ w, h, len: d.length }); },
    say(kind, text) { says.push(text); },
  };
  const d2 = makeDispatcher({
    session: sess, bank: fakeBank, memory: fakeMemory, styles: fakeStyles,
    cfg: {}, bundlePath,
  });

  const r = await d2('perfect_pixel', { source: 'uploaded' });
  ok(r.detected === false && r.noGridDetected === true,
    '16x16 真像素画：自动检测报"无网格"（这是核心算法的既定行为，不是 bug）');
  ok(imports.length === 0, '没有导入 -> 不会开出一个一模一样的文档');
  ok(/do NOT retry/i.test(r.note || ''), '明确告诉模型别盲目重试 gridSize');
  ok(r.distinctColors > 0 && r.distinctColors < 64, '带上颜色数诊断，实际 ' + r.distinctColors);
  ok(r.reason === undefined || typeof r.reason === 'string', '保留了核心给的原始原因');

  // 模型仍然重试（同一个来源）-> 同一轮内直接挡掉，不重复劳动
  const r2 = await d2('perfect_pixel', { source: 'uploaded', gridSize: [16, 16] });
  ok(r2.alreadyProcessed === true, '同一轮里重复调用同一来源被挡');
  ok(imports.length === 0, '仍然没有导入');

  // 换来源：64x64 伪像素画，显式 gridSize -> 正常矫正 + 导入 + 诊断行
  sess.turnProcessed = new Set();
  sess.upload = { buf: makePixelArt(4, 16), w: 64, h: 64, name: 'blurry.ase' };
  const r3 = await d2('perfect_pixel', { source: 'uploaded', gridSize: [16, 16] });
  ok(r3.detected === true && r3.grid === '16x16', '显式 gridSize 照常矫正，实际 ' + r3.grid);
  ok(imports.length === 1 && imports[0].w === 16 && imports[0].h === 16, '真的导入了 16x16');
  ok(says.some((t) => /perfect_pixel: input=64x64/.test(t)), 'P9 诊断行推到了面板');

  // 恒等变换：16x16 图 + gridSize [16,16] -> alreadyPerfect，且不导入
  sess.turnProcessed = new Set();
  sess.upload = { buf: makePixelArt(1, 16), w: 16, h: 16, name: 'identity.ase' };
  const r4 = await d2('perfect_pixel', { source: 'uploaded', gridSize: [16, 16] });
  ok(r4.alreadyPerfect === true, '每格 1px 的恒等变换被识别为 alreadyPerfect');
  ok(imports.length === 1, '恒等变换没有导入（imports 还是 1 次）');
  ok(/no-op|no processing/i.test(r4.note || ''), '说明"这是空操作"');
}

console.log('== P7 ask_user 转发与校验 ==');
{
  calls.length = 0;
  const r = await dispatch('ask_user', { question: '要哪个？', options: ['A', 'B', 'C'] });
  ok(last().kind === 'ask', '消息类型 = ask，实际 ' + last().kind);
  ok(last().payload.question === '要哪个？', '问题转发');
  ok(last().payload.options.length === 3, '选项转发');
  ok(r.ok === true, '结果来自 Lua 侧的回答');

  const r2 = await dispatch('ask_user', { question: '只有空选项', options: ['  ', ''] });
  ok(typeof r2.error === 'string', '空选项被挡，实际 ' + JSON.stringify(r2));

  const r3 = await dispatch('ask_user', { options: ['A', 'B'] });
  ok(typeof r3.error === 'string', '没问题文本被挡');

  const r4 = await dispatch('ask_user', { question: 'x', options: ['1', '2', '3', '4', '5', '6'] });
  ok(r4.error === undefined, '超过 4 个选项时截断而不是报错');

  calls.length = 0;
  await dispatch('ask_user', { question: 'x', options: ['1', '2', '3', '4', '5'] });
  ok(last().payload.options.length === 4, '真的只留了 4 个，实际 ' + last().payload.options.length);
}

console.log('== P14 capabilities 与注册表交叉核对（防漂移）==');
{
  const r = await dispatch('capabilities', {});
  const names = TOOLS.map((t) => t.function.name).sort();
  const listed = Object.keys(r.can.tools).sort();
  ok(JSON.stringify(names) === JSON.stringify(listed),
    'capabilities 列出的工具 == 实际注册的工具（不许漏报/多报）');
  ok(r.cannot.length >= 4, `cannot 段至少 4 条，实际 ${r.cannot.length}`);
  ok(r.cannot.some((x) => /network/i.test(x)), '明确说了不能联网');
  ok(r.cannot.some((x) => /undo/i.test(x)), '明确说了不能自己撤销');
  ok(/only promise/i.test(r.honesty), '带一句"只承诺清单里有的"');
  for (const n of listed) {
    ok(typeof r.can.tools[n] === 'string' && r.can.tools[n].length > 0, `${n} 有一句说明`);
  }
  ok(Array.isArray(r.can.edit_ops), 'edit_ops 是数组（测试替身没有 Aseprite 侧算子表，空数组也算）');
  ok(r.can.workspace && typeof r.can.workspace.enabled === 'boolean',
    'capabilities 说明当前有没有工作区（G6）');
  ok(r.can.workspace.enabled === false, '测试替身没配工作区 -> enabled=false');
  ok(typeof r.can.workspace.note === 'string' && r.can.workspace.note.length > 0,
    '关着的时候要告诉模型怎么开');
  ok(typeof r.can.ui_mode === 'string', 'capabilities 说明当前形态（G6），实际 ' + r.can.ui_mode);
  ok(Array.isArray(r.can.openable_extensions) && r.can.openable_extensions.includes('ase'),
    '明确列出能打开哪些后缀（G6）');
  ok(!r.can.openable_extensions.includes('lua') && !r.can.openable_extensions.includes('txt'),
    '后缀清单里不该有脚本/文本（不能被诱导）');
}

console.log('== G6 capabilities 会反映工作区状态 ==');
{
  const d3 = makeDispatcher({
    session: fakeSession, bank: fakeBank, memory: fakeMemory, styles: fakeStyles,
    cfg: { workspace: { root: 'D:/ws' }, ui: { mode: 'bar_bottom' } }, bundlePath: '',
  });
  const r = await d3('capabilities', {});
  ok(r.can.workspace.enabled === true, '配了工作区 -> enabled=true');
  ok(r.can.workspace.root === 'D:/ws', '带上工作区路径');
  ok(/deliver|交付/.test(r.can.workspace.note || ''), '提示用户怎么"交付"');
  ok(r.can.ui_mode === 'bar_bottom', '反映当前形态，实际 ' + r.can.ui_mode);
}


console.log('== G1 open_document / list_workspace 转发（v0.5.1 补的盲区）==');
{
  calls.length = 0;
  const r = await dispatch('open_document', { path: 'gift/001.ase' });
  ok(last().kind === 'open_doc', '消息类型 = open_doc，实际 ' + last().kind);
  ok(last().payload.path === 'gift/001.ase', 'path 原样转发');
  ok(r.ok === true, '结果来自 Lua 侧');

  const r2 = await dispatch('open_document', {});
  ok(typeof r2.error === 'string', '空 path 被挡住，实际 ' + JSON.stringify(r2));

  const r3 = await dispatch('open_document', { path: '   ' });
  ok(typeof r3.error === 'string', '全空白的 path 也被挡');

  calls.length = 0;
  const r4 = await dispatch('list_workspace', {});
  ok(last().kind === 'list_workspace', '消息类型 = list_workspace，实际 ' + last().kind);
  ok(r4.ok === true, '结果来自 Lua 侧');
}

console.log('== G4 打开文件… 的入口在命令表里 ==');
{
  // 不在桥侧，只是保证菜单行加对了（i18n 在 Lua 测，这里只查工具定义没被改坏）
  const t = TOOLS.find((x) => x.function.name === 'open_document');
  ok(/path/.test(t.function.description), 'open_document 的说明里提到 path');
}


console.log(`\n==== tools_test: ${pass} 通过, ${fail} 失败 ====`);
process.exit(fail === 0 ? 0 : 1);
