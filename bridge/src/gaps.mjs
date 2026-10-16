// 做不到的需求：自动落盘成一份文档，开发者（人或者另一个 agent）读了去实现。
//
// 为什么要有这个：用户在面板里提的需求，模型当场做不到时只会回一句"不行"——
// 那条需求就随着对话滚走了。现在它会被追加到 data/gaps.md：
//   * 结构化（原话 / 为什么做不到 / 变通办法 / 出现的工具和模型）
//   * 同一条重复出现只加计数，不刷屏
//   * 文档顶部写清楚"这是给开发者看的待办"，处理完人工搬进"已处理"段
//
// 写入方有三条路，都必须能落到这儿：
//   1) 模型主动调 log_gap 工具（系统提示里要求它"做不到就说 + 顺手记一笔"）
//   2) 桥自动兜底：工具返回了"不支持/做不到"类错误（模型可能会忘了记）
//   3) 用户在面板里敲 gaps / 做不到，只是查看，不写

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const MAX_TEXT = 400;          // 单条字段上限，挡住整段对话被灌进来
const MAX_ENTRIES = 200;       // 条目上限，超了淘汰最久没出现的
const PC = String.fromCharCode(96);   // 反引号，拼 markdown 行内代码用
const RESOLVED_HEADING = '## 已处理';
const RESOLVED_PLACEHOLDER = '（开发者在这里写结论；例：`v0.5.3 已支持 quantize`、`做不到：Aseprite 没有状态栏 API，见 docs`）';

// 自动兜底：工具结果里出现这些词，就当"这件事现在做不到"
const CAPABILITY_HINTS = [
  'unknown op', 'unknown tool', 'not supported', 'unsupported', 'cannot', "can't",
  'no such', 'not available', 'only 32-bit', 'unsupported tool', '做不到', '不支持',
];

function clip(s, n = MAX_TEXT) {
  const t = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n - 1) + '…' : t;
}

/** 归一化：同一条需求重复提只加计数（去掉标点/大小写/空白差异） */
function normKey(request, why) {
  const join = (s) => String(s || '').toLowerCase().replace(/[\s，。,.!！?？:：;；"'`]/g, '');
  return join(request).slice(0, 120) + '|' + join(why).slice(0, 80);
}

export function looksLikeCapabilityGap(text) {
  const t = String(text || '').toLowerCase();
  return CAPABILITY_HINTS.some((h) => t.includes(h.toLowerCase()));
}

export class GapLog {
  constructor(opts = {}) {
    this.file = opts.file || 'data/gaps.md';
    this.maxEntries = opts.maxEntries || MAX_ENTRIES;
    this.now = opts.now || (() => new Date());
    this.entries = [];
    this.load();
  }

  load() {
    try {
      if (!existsSync(this.file)) return this;
      const raw = JSON.parse(readFileSync(this.file + '.json', 'utf8'));
      if (Array.isArray(raw?.entries)) this.entries = raw.entries;
    } catch {
      this.entries = [];      // 读不到就当空的，别让桥起不来
    }
    return this;
  }

  /** 机器可读的那份（.json）与给人看的那份（.md）一起写；写不进去不算失败 */
  save() {
    try {
      mkdirSync(dirname(this.file), { recursive: true });
      writeFileSync(this.file + '.json',
        JSON.stringify({ entries: this.entries }, null, 2), 'utf8');
      writeFileSync(this.file, this.render(), 'utf8');
      return true;
    } catch {
      return false;
    }
  }

  /**
   * 记一条。同一条（归一化后一样）只加计数 + 更新时间。
   * @returns {{ok:true, added:boolean, count:number, id:number, file:string}}
   */
  add(gap = {}) {
    const request = clip(gap.request);
    const why = clip(gap.why);
    if (!request) return { ok: false, error: 'request is required' };

    const key = normKey(request, why);
    const stamp = this.now().toISOString().replace('T', ' ').slice(0, 16);

    let hit = null;
    for (const e of this.entries) if (e.key === key) hit = e;
    if (hit) {
      hit.count += 1;
      hit.lastSeen = stamp;
      if (gap.workaround) hit.workaround = clip(gap.workaround);
      this.save();
      return { ok: true, added: false, count: hit.count, id: hit.id, file: this.file };
    }

    const entry = {
      id: (this.entries.reduce((m, e) => Math.max(m, e.id || 0), 0) || 0) + 1,
      key,
      request,
      why,
      workaround: clip(gap.workaround),
      tool: clip(gap.tool, 60),
      model: clip(gap.model, 60),
      context: clip(gap.context, 200),
      source: gap.source || 'model',
      firstSeen: stamp,
      lastSeen: stamp,
      count: 1,
    };
    this.entries.push(entry);
    while (this.entries.length > this.maxEntries) {
      // 淘汰最久没被提到的
      let oldest = 0;
      for (let i = 1; i < this.entries.length; i++) {
        if (String(this.entries[i].lastSeen) < String(this.entries[oldest].lastSeen)) oldest = i;
      }
      this.entries.splice(oldest, 1);
    }
    this.save();
    return { ok: true, added: true, count: 1, id: entry.id, file: this.file };
  }

  stats() {
    const open = this.entries.length;
    const total = this.entries.reduce((n, e) => n + (e.count || 1), 0);
    return { entries: open, mentions: total, file: this.file };
  }

  /** 最近 N 条（给面板看） */
  recent(n = 5) {
    return this.entries.slice(-n).map((e) => ({
      id: e.id, request: e.request, why: e.why, count: e.count,
    }));
  }

  /** 读回现有文档里的"已处理"段（开发者手写的结论，重写时必须原样保留） */
  readResolved() {
    try {
      if (!existsSync(this.file)) return '';
      const md = readFileSync(this.file, 'utf8');
      const i = md.indexOf(RESOLVED_HEADING);
      if (i < 0) return '';
      const j = md.indexOf('\n', i);
      return md.slice(j + 1).replace(/^\n+/, '');
    } catch {
      return '';
    }
  }

  /** 关闭一条：从待处理里移走，并在"已处理"段追加一行结论 */
  done(id, note = '') {
    const idx = this.entries.findIndex((e) => String(e.id) === String(id));
    if (idx < 0) return { ok: false, error: `no entry #${id}` };
    const e = this.entries[idx];
    this.entries.splice(idx, 1);
    const stamp = this.now().toISOString().slice(0, 10);
    const line = `- [#${id}] ${e.request} — ${note || '已处理'}（${stamp}）`;
    let body = this.readResolved().trim();
    body = (body === '' || body === RESOLVED_PLACEHOLDER) ? line : body + '\n' + line;
    this.save();
    const kept = this.render();
    writeFileSync(this.file, kept.split(RESOLVED_HEADING)[0] +
      RESOLVED_HEADING + '\n\n' + body + '\n', 'utf8');
    return { ok: true, removed: e.request, file: this.file };
  }

  /** 给人看的那份文档。已处理段是开发者手写的：重写时把现有那段搬过来，别覆盖结论。 */
  render() {
    const rows = [];
    rows.push('# 助手做不到的需求（自动记录）');
    rows.push('');
    rows.push('面板里的助手遇到"我现在做不到"的请求时会自动追加到这份文档。');
    rows.push('**给开发者**：`node src/gaps.mjs list` 看清单，`node src/gaps.mjs done <id> --note "结论"`');
    rows.push('关掉一条（从待处理移走 + 写进下面的"已处理"）。手改"已处理"段也安全，重写时会保留。');
    rows.push('');
    rows.push(`- 文件：${PC}${this.file}${PC}`);
    rows.push(`- 待处理：**${this.entries.length}** 条（累计被提到 ${this.stats().mentions} 次）`);
    rows.push('');
    rows.push('## 待处理');
    rows.push('');
    if (this.entries.length === 0) {
      rows.push('（还没有记录）');
      rows.push('');
    } else {
      for (const e of this.entries) {
        rows.push(`### ${e.id}. ${e.request}　x${e.count}`);
        rows.push('');
        if (e.why) rows.push(`- 做不到的原因：${e.why}`);
        if (e.workaround) rows.push(`- 现在的变通：${e.workaround}`);
        if (e.tool) rows.push(`- 相关工具：${PC}${e.tool}${PC}（${e.source === 'auto' ? '自动记录' : '模型记录'}）`);
        if (e.model) rows.push(`- 模型：${e.model}`);
        if (e.context) rows.push(`- 当时的请求：${e.context}`);
        rows.push(`- 首次 ${e.firstSeen}　最近 ${e.lastSeen}`);
        rows.push('');
      }
    }
    rows.push(RESOLVED_HEADING);
    rows.push('');
    const resolved = this.readResolved().trim();
    rows.push(resolved === '' ? RESOLVED_PLACEHOLDER : resolved);
    rows.push('');
    return rows.join('\n');
  }
}

// ---------------------------------------------------------------- 命令行（"开发者"那一侧）
//   node src/gaps.mjs list                    看还差什么
//   node src/gaps.mjs done <id> --note "结论"   关掉一条（写进"已处理"段）
//   node src/gaps.mjs path                    打印文档路径
if (process.argv[1] && process.argv[1].replace(/\\/g, '/').endsWith('src/gaps.mjs')) {
  const [cmd, arg] = process.argv.slice(2);
  const file = process.env.GAPS_FILE || fileURLToPath(new URL('../data/gaps.md', import.meta.url));
  const log = new GapLog({ file });
  if (cmd === 'list') {
    const st = log.stats();
    console.log(`${st.entries} 条待处理（累计 ${st.mentions} 次）  ${st.file}`);
    for (const e of log.entries) {
      console.log(`  #${e.id}  x${e.count}  ${e.request}`);
      console.log(`      因为: ${e.why}`);
      if (e.workaround) console.log(`      变通: ${e.workaround}`);
    }
  } else if (cmd === 'done') {
    const ni = process.argv.indexOf('--note');
    const res = log.done(arg, ni > 0 ? process.argv[ni + 1] : '');
    console.log(res.ok ? `已关闭 #${arg}：${res.removed}` : `失败：${res.error}`);
    process.exit(res.ok ? 0 : 1);
  } else if (cmd === 'path') {
    console.log(log.file);
  } else {
    console.log('用法: node src/gaps.mjs list | done <id> [--note "结论"] | path');
    process.exit(1);
  }
}
