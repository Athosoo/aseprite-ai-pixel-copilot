// 通用记忆库：把"值得长期记住的事"存下来，需要时按关键词检索。
//
// 和 colorbank.mjs 的分工：
//   colorbank.mjs  色值专用（hex + 场景 + 标签）—— 工具 remember_color / search_colors
//   memory.mjs     通用（配色方案、风格偏好、项目约定、用户口味）—— 工具 remember / recall
//
// 设计目标（用户明确要求：**别吃 token**）：
//   * 存下来的东西【永不】全量注入 prompt —— 只在 recall 时按需取几条出来。
//   * 单条正文有长度上限，总量有上限；超了淘汰"最少被用到"的。
//   * 每次 recall 命中的条目 usedCount +1，于是越常用的越留得住（这就是"进化"）。
//
// 落盘在 bridge/data/memory.json，纯文本，可手工编辑。

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

const MAX_TEXT = 400;      // 单条正文上限（字符）—— 挡住模型往里灌长文
const MAX_TAGS = 8;
const MAX_ENTRIES = 500;   // 总量上限，超了按 usedCount 淘汰
const KINDS = ['color', 'style', 'preference', 'project', 'note'];

export class Memory {
  constructor(file) {
    this.file = file;
    this.entries = [];
    mkdirSync(dirname(file), { recursive: true });
    if (existsSync(file)) {
      try {
        const parsed = JSON.parse(readFileSync(file, 'utf8'));
        if (Array.isArray(parsed)) this.entries = parsed;
      } catch {
        this.entries = [];
      }
    }
  }

  save() {
    writeFileSync(this.file, JSON.stringify(this.entries, null, 2), 'utf8');
  }

  // 超限时淘汰：先按 usedCount 升序，同分再按时间旧的先走。
  // 这样"常用的 + 新写的"留得住，一次性记完再没碰过的会被清掉。
  trim() {
    if (this.entries.length <= MAX_ENTRIES) return 0;
    const sorted = this.entries.slice().sort((a, b) => {
      const uc = (a.usedCount || 1) - (b.usedCount || 1);
      if (uc !== 0) return uc;
      return String(a.updatedAt || a.createdAt).localeCompare(String(b.updatedAt || b.createdAt));
    });
    const drop = this.entries.length - MAX_ENTRIES;
    const doomed = new Set(sorted.slice(0, drop));
    this.entries = this.entries.filter((e) => !doomed.has(e));
    return drop;
  }

  remember({ kind = 'note', text, tags = [], note = '' } = {}) {
    const body = String(text ?? '').trim();
    if (!body) return { error: 'missing text: say what should be remembered' };

    const k = KINDS.includes(String(kind)) ? String(kind) : 'note';
    let clipped = body;
    let truncated = false;
    if (clipped.length > MAX_TEXT) {
      clipped = clipped.slice(0, MAX_TEXT);
      truncated = true;
    }
    const tagList = (Array.isArray(tags) ? tags : [])
      .filter(Boolean).map((t) => String(t).trim()).filter(Boolean).slice(0, MAX_TAGS);

    // 同 kind 下正文完全一样 = 重复记忆，合并标签而不是再存一条
    const existing = this.entries.find((e) => e.kind === k && e.text === clipped);
    const now = new Date().toISOString();
    if (existing) {
      existing.tags = Array.from(new Set([...(existing.tags || []), ...tagList])).slice(0, MAX_TAGS);
      if (note) existing.note = note;
      existing.updatedAt = now;
      this.save();
      return { ok: true, updated: true, id: existing.id, note: 'already known; tags merged' };
    }

    const entry = {
      id: `m${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
      kind: k,
      text: clipped,
      tags: tagList,
      note: String(note || ''),
      createdAt: now,
      updatedAt: now,
      usedCount: 0,
    };
    this.entries.push(entry);
    const dropped = this.trim();
    this.save();
    return {
      ok: true,
      id: entry.id,
      kind: entry.kind,
      truncated: truncated || undefined,
      dropped: dropped || undefined,
      total: this.entries.length,
    };
  }

  recall({ query = '', kind = '', tags = [], limit = 6 } = {}) {
    const k = kind ? String(kind) : '';
    const wanted = (Array.isArray(tags) ? tags : (tags ? [tags] : []))
      .map((t) => String(t).toLowerCase().trim()).filter(Boolean);
    const q = String(query || '').toLowerCase().trim();

    let list = this.entries;
    if (k) list = list.filter((e) => e.kind === k);

    const scored = [];
    for (const e of list) {
      let score = 0;
      if (q) {
        if (e.text.toLowerCase().includes(q)) score += 3;
        if ((e.tags || []).some((t) => String(t).toLowerCase().includes(q))) score += 2;
        if ((e.note || '').toLowerCase().includes(q)) score += 1;
      }
      if (wanted.length) {
        const hits = wanted.filter((w) =>
          (e.tags || []).some((t) => String(t).toLowerCase().includes(w)));
        if (hits.length === 0) continue;   // 指定了标签就必须命中
        score += hits.length * 2;
      }
      if (!q && !wanted.length) score = 1; // 无查询条件 = 按"最近常用"取
      if (score > 0) scored.push({ e, score });
    }

    const out = scored
      .sort((a, b) => {
        if (b.score !== a.score) return b.score - a.score;
        if ((b.e.usedCount || 0) !== (a.e.usedCount || 0)) return (b.e.usedCount || 0) - (a.e.usedCount || 0);
        return String(b.e.updatedAt || b.e.createdAt).localeCompare(String(a.e.updatedAt || a.createdAt));
      })
      .slice(0, Math.max(1, Math.min(20, Number(limit) || 6)));

    // 命中的记一次使用 —— 这是"越用越懂你"的来源
    const now = new Date().toISOString();
    for (const { e } of out) {
      e.usedCount = (e.usedCount || 0) + 1;
      e.lastUsedAt = now;
    }
    if (out.length) this.save();

    return {
      total: list.length,
      returned: out.length,
      entries: out.map(({ e }) => ({
        id: e.id, kind: e.kind, text: e.text, tags: e.tags, note: e.note,
      })),
    };
  }

  list({ kind = '', limit = 20 } = {}) {
    const k = kind ? String(kind) : '';
    const list = (k ? this.entries.filter((e) => e.kind === k) : this.entries)
      .slice()
      .sort((a, b) => (b.usedCount || 0) - (a.usedCount || 0))
      .slice(0, Math.max(1, Math.min(100, Number(limit) || 20)));
    return {
      total: this.entries.length,
      returned: list.length,
      entries: list.map((e) => ({ id: e.id, kind: e.kind, text: e.text, tags: e.tags })),
    };
  }

  forget({ id } = {}) {
    const i = this.entries.findIndex((e) => e.id === String(id || ''));
    if (i < 0) return { error: `no memory with id ${id}` };
    const [gone] = this.entries.splice(i, 1);
    this.save();
    return { ok: true, removed: { id: gone.id, text: gone.text } };
  }

  get size() {
    return this.entries.length;
  }
}

export { KINDS, MAX_TEXT, MAX_ENTRIES };
