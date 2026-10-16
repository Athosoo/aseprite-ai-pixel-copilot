// 对话历史的持久化 + 压缩（上下文管理）
//
// 问题：原来 history 只放在 Session 的内存里，而且只是 `slice(-12)` 硬砍 ——
//   * 重启桥（或重启 Aseprite）就忘光了，用户感觉"它没有记忆"；
//   * 硬砍尾巴会把"我们刚才决定用哪个颜色/哪个文件"整段丢掉。
//
// 这个模块做四件事：
//   1) **落盘**：历史写到对话文件，重启继续。
//   2) **压缩**：超过预算时，把最老的一段交给 LLM 摘要成几句话，
//      作为常驻摘要挂在系统提示后面，只保留最近的原始消息。
//   3) **留档**（v0.5.8）：压缩掉的老消息进 `archive`，**不再从磁盘上消失** ——
//      摘要只是"不再发给模型"，不是"删掉"。以前的写法是 `messages = keep` 直接落盘，
//      老消息就真没了。
//   4) **回放**（v0.5.8）：面板上滚过去的那段记录（`log`）也存下来。
//      只存消息不够 —— 用户看到的"它记得我们聊过"是屏幕上那些字，
//      而面板的滚回区原本只在 Lua 内存里，重启 Aseprite 就是一片空白。
//
// 预算按 **token 估算**算（不是条数）：条数和长度没关系，一条字符网格能顶几十条闲聊。
// 估法故意保守：中英混排按 2.5 字符 ≈ 1 token 折算（中文接近 1:1、英文约 4:1）。

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

const NL = String.fromCharCode(10);   // 不写字面量换行，免得被各层转义吃掉

export const DEFAULT_BUDGET_TOKENS = 16000;   // 对话历史上限（超出就把最老的压缩掉）
export const MAX_BUDGET_TOKENS = 200000;      // 想开大可以，但别把 128k 窗口撑爆
const MAX_SUMMARY_CHARS = 1200;               // 单次摘要字数上限
const MAX_SUMMARY_TOTAL = 3600;               // 累计摘要上限（超了留最新的那截）
const MAX_CONTENT_CHARS = 2000;               // 单条消息进摘要前的截断，防止把整张字符网格喂进去

export const DEFAULT_ARCHIVE_CAP = 2000;      // 留档上限（条）；超了丢最老的
export const DEFAULT_LOG_CAP = 400;           // 面板回放行数上限
const MAX_TITLE_CHARS = 24;

/** 用户消息被 buildUserMessage 包成 `[Current canvas state]…[User request]…`，标题要取后面那截 */
const USER_REQUEST_MARK = '[User request]';

/** 粗估 token 数。故意不引入 tokenizer：这里只需要"别超窗"的量级判断。 */
export function estimateTokens(s) {
  return Math.ceil(String(s == null ? '' : s).length / 2.5);
}

/** 一条消息的 token 估算（正文 + 工具调用的参数） */
export function messageTokens(m) {
  if (!m) return 0;
  let n = estimateTokens(typeof m.content === 'string' ? m.content : '');
  if (Array.isArray(m.tool_calls)) {
    for (const c of m.tool_calls) {
      n += estimateTokens(c?.function?.arguments || '') + 8;   // 名字和结构占几 token
    }
  }
  return n;
}

export function clampBudget(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v <= 0) return DEFAULT_BUDGET_TOKENS;
  return Math.min(MAX_BUDGET_TOKENS, Math.max(1000, Math.round(v)));
}

/**
 * 从一条 user 消息里抠出用户真正打的那句话（去掉画布上下文那一段）。
 * 标题就靠它 —— 直接拿 content 开头会是 "[Current canvas state]"。
 */
export function userRequestOf(content) {
  const s = typeof content === 'string' ? content : '';
  const i = s.indexOf(USER_REQUEST_MARK);
  return (i >= 0 ? s.slice(i + USER_REQUEST_MARK.length) : s).trim();
}

/** 从消息数组里派生一个标题：第一条用户消息的首行，按字符数截断 */
export function deriveTitle(messages, fallback = '') {
  for (const m of Array.isArray(messages) ? messages : []) {
    if (m?.role !== 'user') continue;
    const text = userRequestOf(m.content);
    if (!text) continue;
    const first = text.split(NL)[0].trim();
    const chars = [...first];                       // 按字符数截，不是字节数
    if (chars.length <= MAX_TITLE_CHARS) return first;
    return chars.slice(0, MAX_TITLE_CHARS).join('') + '…';
  }
  return fallback;
}

export class Conversation {
  /**
   * @param {object} opts
   *   file          持久化路径（data/conversations/<id>.json）
   *   id            对话 id（缺省用文件名）
   *   title         标题（缺省空，之后由 deriveTitle 填）
   *   budgetTokens  历史预算（token 估算）；超了触发压缩
   *   keepRatio     压缩后保留多少比例的最新原文（默认 0.4）
   *   minKeep       至少保留几条（默认 4），免得压缩完只剩一条孤零零的
   *   maxMessages   条数安全阀（默认 120）：工具调用刷屏时兜底
   *   archiveCap    留档上限（默认 2000 条）
   *   logCap        面板回放行上限（默认 400 行）
   *   now           取当前时间的函数（测试用，保证时间戳确定）
   */
  constructor(opts = {}) {
    this.file = opts.file || join(process.cwd(), 'data', 'history.json');
    this.budgetTokens = clampBudget(opts.budgetTokens ?? DEFAULT_BUDGET_TOKENS);
    this.keepRatio = opts.keepRatio ?? 0.4;
    this.minKeep = opts.minKeep ?? 4;
    this.maxMessages = opts.maxMessages ?? 120;
    this.archiveCap = opts.archiveCap ?? DEFAULT_ARCHIVE_CAP;
    this.logCap = opts.logCap ?? DEFAULT_LOG_CAP;
    this.now = opts.now || (() => new Date());

    const stamp = this.now().toISOString();
    this.id = opts.id || basename(this.file).replace(/\.json$/i, '');
    this.title = opts.title || '';
    this.createdAt = opts.createdAt || stamp;
    this.updatedAt = opts.updatedAt || stamp;
    this.messages = [];
    this.summary = '';
    this.archive = [];
    this.log = [];
    this.load();
  }

  load() {
    try {
      if (!existsSync(this.file)) return this;
      const raw = JSON.parse(readFileSync(this.file, 'utf8'));
      if (Array.isArray(raw.messages)) this.messages = raw.messages;
      if (typeof raw.summary === 'string') this.summary = raw.summary;
      if (typeof raw.id === 'string' && raw.id) this.id = raw.id;
      if (typeof raw.title === 'string') this.title = raw.title;
      if (typeof raw.createdAt === 'string' && raw.createdAt) this.createdAt = raw.createdAt;
      if (typeof raw.updatedAt === 'string' && raw.updatedAt) this.updatedAt = raw.updatedAt;
      if (Array.isArray(raw.archive)) this.archive = raw.archive;
      if (Array.isArray(raw.log)) this.log = raw.log;
    } catch {
      // 文件坏了就当新的开始，别让桥起不来
      this.messages = [];
      this.summary = '';
      this.archive = [];
      this.log = [];
    }
    return this;
  }

  /**
   * 丢弃末尾"半截"的工具调用组。
   * 被中断时历史可能停在 assistant(tool_calls)、而工具结果还没写回来 ——
   * 原样发给 API 会被拒（每个 tool_call 都必须有对应的 tool 消息）。
   */
  trimIncompleteTail() {
    const m = this.messages;
    let i = m.length;
    let toolStart = i;
    while (toolStart > 0 && m[toolStart - 1].role === 'tool') toolStart--;
    if (toolStart < i) {
      const a = toolStart - 1;
      const asst = a >= 0 ? m[a] : null;
      if (asst && asst.role === 'assistant' && asst.tool_calls?.length) {
        const want = new Set(asst.tool_calls.map((c) => c.id));
        const got = new Set(m.slice(toolStart, i).map((t) => t.tool_call_id));
        if (![...want].every((id) => got.has(id))) i = a;   // 不完整：整组丢掉
      } else {
        i = toolStart;                                     // 孤立的 tool 结果，丢掉
      }
    }
    while (i > 0 && m[i - 1].role === 'assistant' && m[i - 1].tool_calls?.length) i--;
    if (i !== m.length) this.messages = m.slice(0, i);
    return this;
  }

  save() {
    this.trimIncompleteTail();
    if (!this.title) this.title = deriveTitle(this.messages);
    try {
      mkdirSync(dirname(this.file), { recursive: true });
      const stamp = this.now().toISOString();
      if (stamp > this.updatedAt) this.updatedAt = stamp;
      writeFileSync(this.file, JSON.stringify({
        id: this.id,
        title: this.title,
        createdAt: this.createdAt,
        updatedAt: this.updatedAt,
        summary: this.summary,
        messages: this.messages,
        archive: this.archive,
        log: this.log,
      }, null, 2), 'utf8');
      return true;
    } catch {
      return false;                    // 存不下来不影响本次会话
    }
  }

  /**
   * 清空这个对话（消息/摘要/留档/回放），但**保留 id 和标题**。
   * "清空"不等于"删掉这个对话" —— 删对话是 store 的事（移进回收站）。
   */
  reset() {
    this.messages = [];
    this.summary = '';
    this.archive = [];
    this.log = [];
    this.save();
    return { ok: true, messages: 0, tokens: 0, summary: '' };
  }

  /** 面板回放行：屏幕上滚过去的每一行。i18nKey 有值时面板会本地化重渲染。 */
  pushLog(kind, text, i18nKey) {
    const t = String(text == null ? '' : text);
    if (!t) return this;
    const row = { kind: String(kind || 'info'), text: t };
    if (i18nKey) row.i18n = String(i18nKey);
    this.log.push(row);
    if (this.log.length > this.logCap) this.log = this.log.slice(-this.logCap);
    return this;
  }

  /** 留档：压缩掉的老消息进 archive（只留档，永不外发） */
  _archive(msgs) {
    if (!Array.isArray(msgs) || msgs.length === 0) return;
    this.archive = this.archive.concat(msgs);
    if (this.archive.length > this.archiveCap) this.archive = this.archive.slice(-this.archiveCap);
  }

  stats() {
    return {
      id: this.id,
      title: this.title,
      messages: this.messages.length,
      tokens: this.usedTokens(),
      budgetTokens: this.budgetTokens,
      summaryChars: this.summary.length,
      archived: this.archive.length,
      logLines: this.log.length,
    };
  }

  /** 当前历史占的 token（估算） */
  usedTokens() {
    let n = 0;
    for (const m of this.messages) n += messageTokens(m);
    return n;
  }

  push(msg) {
    this.messages.push(msg);
    return this;
  }

  /** 摘要段（挂到系统提示后面，每步重取：压缩完立刻生效）。 */
  summaryBlock() {
    if (!this.summary) return '';
    return '[Earlier conversation summary -- you already know this, do not ask again]' + NL + this.summary;
  }

  /** 拼给 LLM 的完整消息序列（系统提示 + 摘要 + 历史） */
  toMessages(systemPrompt) {
    const out = [{ role: 'system', content: systemPrompt }];
    const block = this.summaryBlock();
    if (block) out.push({ role: 'system', content: block });
    return out.concat(this.messages);
  }

  needsCompaction() {
    return this.usedTokens() > this.budgetTokens || this.messages.length > this.maxMessages;
  }


  /**
   * 切分：新的留下、老的拿去摘要。
   * 从最新往回攒，攒够 keepRatio*budget（且至少 minKeep 条）就停；
   * 然后对齐到"安全边界"—— 别把 assistant(tool_calls) 和它的结果切开。
   */
  _split() {
    const n = this.messages.length;
    // 保留量：预算的 keepRatio，但至少 200 token，且必须给"可压缩段"留下 200 token 的余地
    // （预算调小的时候不能把全部预算都划给"保留"，否则永远压不动）
    const keepTokens = Math.min(
      Math.max(200, Math.floor(this.budgetTokens * this.keepRatio)),
      Math.max(200, this.budgetTokens - 200),
    );
    // 至少能丢掉一条：minKeep 比消息总数还大时按"留一条"算
    const minKeep = Math.min(this.minKeep, Math.max(0, n - 1));

    let acc = 0;
    let cut = n;
    while (cut > 0) {
      if (n - cut >= minKeep && acc >= keepTokens) break;
      cut--;
      acc += messageTokens(this.messages[cut]);
    }
    // drop 段不能以 assistant(tool_calls) 结尾（它的结果落在被保留的那段里）
    while (cut > 0) {
      const m = this.messages[cut - 1];
      if (m.role === 'assistant' && m.tool_calls?.length) cut--;
      else break;
    }
    // 保留段也不能以孤立的 tool 结果开头（找不到它的调用方）
    while (cut < n && this.messages[cut].role === 'tool') cut++;
    // 对齐之后兜底：至少留 minKeep 条，别把整段历史连根拔了
    cut = Math.min(cut, Math.max(0, n - Math.max(minKeep, 1)));
    return { drop: this.messages.slice(0, cut), keep: this.messages.slice(cut) };
  }

  _renderForSummary(chunk) {
    const lines = [];
    for (const m of chunk) {
      const text = typeof m.content === 'string' ? m.content : '';
      if (m.role === 'tool') continue;               // 工具结果是噪声，摘要里不要
      const who = m.role === 'assistant' ? 'assistant' : (m.role === 'user' ? 'user' : m.role);
      const body = text.slice(0, MAX_CONTENT_CHARS);
      if (body.trim()) lines.push(`${who}: ${body}`);
      if (m.tool_calls?.length) {
        // 工具名要留着：模型才知道"我之前调过 draw_art"这种事实
        const names = m.tool_calls.map((c) => c.function?.name).filter(Boolean).join(', ');
        if (names) lines.push(`assistant called: ${names}`);
      }
    }
    return lines.join(NL);
  }

  /**
   * 压缩：把最老的一段交给 summarize(text) 摘要。
   * 摘要函数抛错/返回空 -> 不压缩（宁可留着原文，也别把上下文弄丢）。
   * @returns {Promise<{compacted:boolean, summary?:string, dropped?:number, tokensBefore?:number, reason?:string}>}
   */
  async compact(summarize) {
    if (!this.needsCompaction()) return { compacted: false, reason: 'under-budget' };

    this.trimIncompleteTail();      // 先修掉半截的工具组，再决定切哪儿
    const before = this.usedTokens();
    const { drop, keep } = this._split();
    if (drop.length === 0) return { compacted: false, reason: 'nothing-to-drop' };

    const text = this._renderForSummary(drop);
    if (!text.trim()) {
      // 全是工具噪音：直接丢掉，不用麻烦 LLM（但照样留档）
      this._archive(drop);
      this.messages = keep;
      this.save();
      return { compacted: true, summary: this.summary, dropped: drop.length, tokensBefore: before, reason: 'tool-noise-only' };
    }

    let fresh = '';
    try {
      fresh = String((await summarize(text)) || '').trim();
    } catch (e) {
      return { compacted: false, reason: `summarize failed: ${e?.message || e}` };
    }
    if (!fresh) return { compacted: false, reason: 'empty summary' };

    this.summary = (this.summary ? this.summary + NL : '') + fresh;
    if (this.summary.length > MAX_SUMMARY_TOTAL) {
      // 摘要本身也不能无限涨：留下最后一截（越新的越相关）
      this.summary = this.summary.slice(-MAX_SUMMARY_TOTAL);
    }
    this._archive(drop);          // 摘要 ≠ 删除：原文进留档
    this.messages = keep;
    this.save();
    return { compacted: true, summary: this.summary, dropped: drop.length, tokensBefore: before, archived: this.archive.length };
  }
}
