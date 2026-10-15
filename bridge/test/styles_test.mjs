// styles.mjs 的单元测试（不联网、不碰 Aseprite）。
//
//   cd bridge && node test/styles_test.mjs
//
// 重点验的是"省 token"那一条：切换风格时只渲染**当前这一个**，
// 以及三层优先级（用户 > 仓库文件 > 代码内置）和落盘前的字段清洗。

import { Styles } from '../src/styles.mjs';
import { rmSync, mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + extra : '')); }
};

const root = mkdtempSync(join(tmpdir(), 'styletest-'));
const builtinDir = join(root, 'styles');
const userDir = join(root, 'data', 'styles');
mkdirSync(builtinDir, { recursive: true });

const s = new Styles({ builtinDir, userDir });

console.log('== v0.5.2 图层名必须 ASCII ==');
{
  const bad = s.save('layer-name-check', { layers: ['主体', 'base'] });
  ok(bad.error !== undefined, '中文图层名被拒');
  ok(/ASCII/.test(bad.error), '报错说明是 ASCII 的问题');

  const good = s.save('layer-name-ok', { layers: ['shadow', 'base', 'detail', 'highlight'] });
  ok(good.ok === true, '全英文图层名可以保存');
  const g = s.get('layer-name-ok');
  ok(g.layers.length === 4 && g.layers[0] === 'shadow', '图层顺序保留（从底到顶）');
}

console.log('== 内置风格 ==');
{
  const names = s.names();
  ok(names.includes('pixel-icon'), '有 pixel-icon');
  ok(names.includes('stardew'), '有 stardew');
  ok(names.includes('flat-minimal'), '有 flat-minimal');
  // 用户目录里可能有自己存的风格，所以只断言三个内置都在（不再断言恰好 3 个）
  ok(['pixel-icon', 'stardew', 'flat-minimal'].every((n) => names.includes(n)), '内置三个都在');
  ok(names.join(',') === names.slice().sort().join(','), '名字是排好序的');

  const st = s.get('pixel-icon');
  ok(st.size[0] === 16 && st.size[1] === 16, 'pixel-icon 推荐 16x16');
  ok(Array.isArray(st.layers) && st.layers.length > 0, '带图层结构');
  ok(Array.isArray(st.rules) && st.rules.length > 0, '带作画规矩');
  ok(s.get('nope') === null, '不存在的风格返回 null');
  ok(s.get('') === null, '空名字返回 null');
}

console.log('== describe：只渲染当前这一个 ==');
{
  const text = s.describe('stardew');
  ok(typeof text === 'string' && text.length > 0, '渲染出文本');
  ok(text.includes('16x32'), '带上了推荐尺寸');
  ok(text.includes('#3A2412'), '带上了调色板');
  ok(text.includes('阴影'), '带上了图层结构');
  ok(text.includes('Rules:'), '带上了规矩');

  // 关键：别的风格的调色板不能漏进来，否则就白省 token 了
  ok(!text.includes('#2E86DE'), '没混进 pixel-icon 的颜色');
  ok(!text.includes('#3498DB'), '没混进 flat-minimal 的颜色');

  // 体量得小 —— 这条是设计目标，写死一个上限当回归护栏
  ok(text.length < 700, `渲染文本够短（${text.length} 字符）`);
  ok(s.describe('nope') === null, '不存在的风格返回 null');
}

console.log('== save：清洗 + 落盘 ==');
{
  const r = s.save('my-style', {
    label: '我的风格',
    size: [24, 24],
    palette: ['#FFFFFF', '  #000000  ', 'not-a-colour', '#GGGGGG'],
    layers: ['base', 'top'],
    rules: ['规则一', '规则二'],
    notes: '随手记',
  });
  ok(r.ok === true, '保存成功');
  ok(s.names().includes('my-style'), '保存后能列出来');

  const st = s.get('my-style');
  ok(st.source === 'user', '来源标成 user');
  ok(st.palette.length === 2, '非法色值被过滤掉，实际 ' + st.palette.length);
  ok(st.palette[1] === '#000000', '色值首尾空格被去掉');
  ok(st.size[0] === 24 && st.size[1] === 24, '尺寸保留');
  ok(st.layers[0] === 'base' && st.layers[1] === 'top', '图层顺序保留（底 -> 上）');
}

console.log('== save：名字校验 ==');
{
  ok(s.save('', {}).error !== undefined, '空名字被拒');
  ok(s.save('   ', {}).error !== undefined, '纯空格被拒');
  ok(s.save('a/b', {}).error !== undefined, '带斜杠被拒（会跑到目录外）');
  ok(s.save('a.b', {}).error !== undefined, '带点被拒');
  // v0.5.2：名字会当文件名，改成只允许 ASCII（用户要求：无论界面语言一律英文）
  ok(s.save('中文风格', {}).error !== undefined, '中文名字现在被拒（它会变成文件名）');
  ok(/ASCII/.test(s.save('中文风格', {}).error), '报错里说清了原因');
  ok(s.save('note-paper', { label: '便签纸风格' }).ok === true, '英文名 + 中文 label 照常可以');
  ok(s.save('my-style-2', {}).ok === true, '字母数字连字符允许');
}

console.log('== save：超长内容被截断 ==');
{
  const many = Array.from({ length: 50 }, (_, i) => '规则' + i);
  s.save('long', { rules: many, notes: 'x'.repeat(5000) });
  const st = s.get('long');
  ok(st.rules.length === 12, '规则最多留 12 条，实际 ' + st.rules.length);
  ok(st.notes.length === 300, 'notes 截到 300 字符，实际 ' + st.notes.length);
}

console.log('== 三层优先级：用户 > 仓库文件 > 代码内置 ==');
{
  // 仓库文件覆盖代码内置
  writeFileSync(join(builtinDir, 'stardew.json'), JSON.stringify({
    name: 'stardew', label: '仓库版星露谷', size: [32, 32], palette: ['#111111'], layers: [], rules: [],
  }), 'utf8');
  s.reload();
  ok(s.get('stardew').label === '仓库版星露谷', '仓库文件覆盖了代码内置');
  ok(s.get('stardew').source === 'file', '来源标成 file');

  // 用户目录再覆盖仓库文件
  writeFileSync(join(userDir, 'stardew.json'), JSON.stringify({
    name: 'stardew', label: '我的星露谷', size: [48, 48], palette: ['#222222'], layers: [], rules: [],
  }), 'utf8');
  s.reload();
  ok(s.get('stardew').label === '我的星露谷', '用户目录覆盖了仓库文件');
  ok(s.get('stardew').source === 'user', '来源标成 user');
  ok(s.get('pixel-icon').label === '像素图标', '没被覆盖的内置风格还在');
}

console.log('== 坏文件不拖垮整个库 ==');
{
  writeFileSync(join(userDir, 'broken.json'), '{ this is not json', 'utf8');
  s.reload();
  ok(s.names().includes('pixel-icon'), '坏 json 之后内置风格仍可读');
  ok(!s.names().includes('broken'), '坏文件本身没被当成风格');
}

rmSync(root, { recursive: true, force: true });
console.log(`\n==== styles_test: ${pass} 通过, ${fail} 失败 ====`);
process.exit(fail === 0 ? 0 : 1);
