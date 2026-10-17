// 本地工具开销基准：注册表查找 + 参数转发 + 账本记账的总开销（arch §8 的 <50ms 那条）。
//
//   node tests/bench/local-tool-latency.mjs
//
// 只量"本地"这一段：Lua 侧真的干活的时间不算在这里，否则测的就是 Aseprite 而不是桥。
// 输出 JSON（机器可读），超预算时退出码非 0。

import { performance } from 'node:perf_hooks';
import { makeDispatcher } from '../../bridge/src/tools.mjs';

const BUDGET_MS = 50;
const WARMUP = 30;
const ITERATIONS = 300;

// 立刻返回的替身：这一段开销里不应该包含网络、LLM 或 Lua 往返
const session = {
  request: async (kind) => ({ ok: true, kind }),
  upload: null,
  turnProcessed: new Set(),
  say: () => {},
};
const bank = { remember: (a) => ({ ok: true, a }), search: (a) => ({ ok: true, a }) };
const memory = { remember: (a) => ({ ok: true, a }), recall: (a) => ({ ok: true, a }), forget: (a) => ({ ok: true, a }) };
const styles = { names: () => ['s'], get: () => ({ name: 's', label: 'S', size: [16, 16], palette: ['#000'], layers: [] }), save: (n, spec) => ({ ok: true, n, spec }) };

const dispatch = makeDispatcher({
  session, bank, memory, styles, cfg: {}, bundlePath: '',
  getActiveStyle: () => '', setActiveStyle: () => {},
});

const CALLS = [
  ['canvas_info', {}],
  ['list_versions', {}],
  ['snapshot', { label: 'bench' }],
  ['style_list', {}],
  ['style_use', { name: 's' }],
  ['capabilities', {}],
  ['remember', { text: 'bench note' }],
  ['search_colors', { query: 'red' }],
  ['unknown_tool', {}],           // 未注册路径也要快：模型幻觉出来的名字不应该拖慢这一轮
];

const samples = [];
for (let w = 0; w < WARMUP; w++) for (const c of CALLS) await dispatch(c[0], c[1]);

for (let i = 0; i < ITERATIONS; i++) {
  for (const c of CALLS) {
    const t0 = performance.now();
    await dispatch(c[0], c[1]);
    samples.push(performance.now() - t0);
  }
}

samples.sort((a, b) => a - b);
const sum = samples.reduce((a, b) => a + b, 0);
const pick = (p) => samples[Math.min(samples.length - 1, Math.floor(samples.length * p))];

const report = {
  ok: samples[samples.length - 1] < BUDGET_MS,
  budgetMs: BUDGET_MS,
  iterations: ITERATIONS,
  callsPerIteration: CALLS.length,
  samples: samples.length,
  tools: CALLS.map((c) => c[0]),
  msAvg: Number((sum / samples.length).toFixed(4)),
  msP50: Number(pick(0.5).toFixed(4)),
  msP95: Number(pick(0.95).toFixed(4)),
  msMax: Number(samples[samples.length - 1].toFixed(4)),
};

console.log(JSON.stringify(report, null, 2));
if (!report.ok) {
  console.error('local tool latency over budget: ' + report.msMax + 'ms >= ' + BUDGET_MS + 'ms');
  process.exit(1);
}
