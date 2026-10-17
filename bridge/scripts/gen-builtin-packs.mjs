// 内置能力包的生成器：按注册表的 description/inputSchema 重新对齐 packs/builtin-*/bridge/tools.mjs。
//
//   node bridge/scripts/gen-builtin-packs.mjs
//
// 只重写声明部分（description / inputSchema / manifest.ops），**保留每个工具已有的 run 实现**：
// 实现是手写的，脚本无权覆盖 —— 找不到现有实现就直接报错，绝不写一个空壳进去。
// 输出目录按脚本自身位置推算，不依赖 cwd 或环境变量（曾经因此把文件写到 undefined/ 下）。

import { mkdirSync, readFileSync, existsSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));      // <repo>/bridge/scripts
const BRIDGE = join(HERE, '..');                           // <repo>/bridge
const PACKS = join(BRIDGE, 'packs');

const PACKS_SPEC = [
  { id: 'builtin-canvas', name: '画布与尺寸', tools: ['canvas_info', 'apply_ops', 'crop', 'scale', 'canvas_size'] },
  { id: 'builtin-style', name: '风格库', tools: ['style_list', 'style_use', 'style_save'] },
  { id: 'builtin-assist', name: '对话与自省', tools: ['ask_user', 'log_gap', 'capabilities'] },
  { id: 'builtin-workspace', name: '工作区与文档', tools: ['open_document', 'list_workspace'] },
  { id: 'builtin-draw', name: '作画与图层', tools: ['new_sprite', 'add_layer', 'draw_art'] },
  { id: 'builtin-pixel', name: '图像矫正', tools: ['perfect_pixel'] },
  { id: 'builtin-versions', name: '版本与快照', tools: ['snapshot', 'rollback', 'list_versions'] },
  { id: 'builtin-memory', name: '记忆与色库', tools: ['remember', 'recall', 'forget', 'remember_color', 'search_colors'] },
];

const KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

// 手写风格的对象字面量：键能裸写就裸写，字符串一律 JSON.stringify（不碰内容）
function emit(v, pad) {
  const p = ' '.repeat(pad);
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) {
    if (v.length === 0) return '[]';
    const flat = v.every((x) => x === null || typeof x !== 'object') && JSON.stringify(v).length <= 96;
    if (flat) return JSON.stringify(v);
    return '[\n' + v.map((x) => p + '  ' + emit(x, pad + 2) + ',').join('\n') + '\n' + p + ']';
  }
  const keys = Object.keys(v);
  if (keys.length === 0) return '{}';
  return '{\n' + keys.map((k) => p + '  ' + (KEY.test(k) ? k : JSON.stringify(k)) + ': ' + emit(v[k], pad + 2)).join(',\n') + '\n' + p + '}';
}

const BACKTICK = String.fromCharCode(96);

// 取一个工具已有的 run 函数体：从 "async run(ctx, input) {" 的花括号配对扫到结尾。
// 扫描时跳过字符串/模板/注释，否则实现里的花括号会让配对提前结束（真的会踩）。
function extractRun(src, name) {
  const anchor = '      name: ' + JSON.stringify(name) + ',';
  const start = src.indexOf(anchor);
  if (start < 0) return null;
  const runAt = src.indexOf('      async run(ctx, input) {', start);
  if (runAt < 0) return null;

  const open = src.indexOf('{', runAt);
  let depth = 0;
  let i = open;
  let quote = '';
  let line = false;
  let block = false;
  for (; i < src.length; i++) {
    const ch = src[i];
    const next = src[i + 1];
    if (line) { if (ch === '\n') line = false; continue; }
    if (block) { if (ch === '*' && next === '/') { block = false; i++; } continue; }
    if (quote) {
      if (ch === '\\') { i++; continue; }
      if (ch === quote) quote = '';
      continue;
    }
    if (ch === '/' && next === '/') { line = true; i++; continue; }
    if (ch === '/' && next === '*') { block = true; i++; continue; }
    if (ch === "'" || ch === '"' || ch === BACKTICK) { quote = ch; continue; }
    if (ch === '{') depth++;
    else if (ch === '}') { depth--; if (depth === 0) break; }
  }
  if (depth !== 0) throw new Error('unbalanced run() body for ' + name);
  // 首尾空行要规整掉，否则每跑一次就多一个空行（脚本必须幂等，不然 diff 里全是噪声）
  const lines = src.slice(open + 1, i).split('\n');
  while (lines.length && lines[0].trim() === '') lines.shift();
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  return '\n' + lines.join('\n');
}

// 声明以已生效的注册表为准（真相只有一个：packs 自己）
const { registry } = await import(pathToFileURL(join(BRIDGE, 'src', 'tools.mjs')).href);

let written = 0;
let changed = 0;
for (const p of PACKS_SPEC) {
  const dir = join(PACKS, p.id);
  const file = join(dir, 'bridge', 'tools.mjs');
  const before = existsSync(file) ? readFileSync(file, 'utf8') : '';

  mkdirSync(join(dir, 'bridge'), { recursive: true });

  const parts = [];
  parts.push('// ' + p.name + ' —— 桥侧注册项（OpenAI function 描述由 registry 统一生成，这里只声明）。');
  parts.push('// manifest.ops 列出本包贡献的工具名：护栏「必须同名」正是按这张表核对注册表。');
  parts.push('export default {');
  parts.push('  tools: [');
  for (const name of p.tools) {
    const spec = registry.get(name);
    if (!spec) throw new Error('registry has no tool named ' + name);
    if (!spec.pack.startsWith('builtin-') || spec.pack === 'builtin-evolution') {
      throw new Error(name + ' is owned by ' + spec.pack + ', refusing to regenerate');
    }
    const body = extractRun(before, name);
    if (body === null) throw new Error('no existing run() for ' + name + ' in ' + file + ' -- refusing to write a stub');
    parts.push('    {');
    parts.push('      name: ' + JSON.stringify(spec.name) + ',');
    parts.push('      description: ' + JSON.stringify(spec.description) + ',');
    parts.push('      inputSchema: ' + emit(spec.inputSchema, 6) + ',');
    parts.push('      async run(ctx, input) {');
    parts.push(body);
    parts.push('      },');
    parts.push('    },');
  }
  parts.push('  ],');
  parts.push('};');
  parts.push('');

  const out = parts.join('\n');
  if (out !== before) changed++;
  writeFileSync(file, out, 'utf8');
  written++;
}

console.log('aligned ' + written + ' builtin packs under ' + PACKS + ' (' + changed + ' changed)');
