// 多对话管理：一个对话一个文件，外加"当前是哪个"的记账。
//
// 为什么需要它（v0.5.8）：
//   * 原来全桥只有一个 `data/history.json` —— 想开一条新话题只能把旧的清掉；
//   * 面板的滚回区在 Lua 内存里，重启 Aseprite 就一片空白，用户以为"它失忆了"。
//
// 设计要点：
//   * **一个对话 = 一个 JSON 文件**（`data/conversations/<id>.json`），
//     里面装消息 + 摘要 + 留档 + 回放行（字段见 history.mjs 的 Conversation）。
//   * **删除 = 移进 `trash/`**，不是真删 —— 手滑删掉还能捞回来。
//   * **至少留一个对话**：删最后一个会被拒（否则界面没地方可去）。
//   * **迁移**：老的 `data/history.json` 自动变成第一个对话，原文件改名留底。
//   * `current` 是**稳定引用**：切对话时换 `file` 再 `load()`，所以 server 里
//     所有 `history.xxx` 调用一行都不用改。
//
// 一个已知边界：桥是一个进程（一个端口），服务所有 Aseprite 窗口，
// 所以"活动对话"是全局的 —— 多开窗口会共用同一个。协议里留了
// `hello.conversation` 字段，将来要"每窗口一个对话"不用改结构。

import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { Conversation, deriveTitle, messageTokens } from './history.mjs';

const TRASH_DIR = 'trash';
const ID_RE = /^[A-Za-z0-9._-]+$/;

function pad(n) { return String(n).padStart(2, '0'); }

/** 对话 id：c-YYYYMMDD-xxxx（纯 ASCII，当文件名安全） */
export function newConversationId(now = new Date()) {
  const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}`;
  let tail = '';
  for (let i = 0; i < 4; i++) tail += 'abcdefghijklmnopqrstuvwxyz0123456789'[Math.floor(Math.random() * 36)];
  return `c-${stamp}-${tail}`;
}

/** 从消息数组派生标题（没有用户消息时给个兜底名） */
export function titleFromMessages(messages, fallback = '新对话') {
  return deriveTitle(messages, fallback);
}

export class ConversationStore {
  /**
   * @param {object} opts
   *   dir           对话目录（data/conversations）
   *   budgetTokens  传给每个 Conversation
   *   legacyFile    老的单文件历史（data/history.json），存在就迁移
   *   activeId      上次的活动对话 id（config.json 里的 activeConversation）
   *   now           取当前时间的函数（测试用）
   */
  constructor(opts = {}) {
    this.dir = opts.dir;
    this.budgetTokens = opts.budgetTokens;
    this.legacyFile = opts.legacyFile || '';
    this.now = opts.now || (() => new Date());
    this.trashDir = join(this.dir, TRASH_DIR);
    mkdirSync(this.dir, { recursive: true });

    this._migrateLegacy();

    const ids = this._ids();
    let id = String(opts.activeId || '');
    if (!id || !ids.includes(id)) {
      id = this._mostRecentId(ids) || this._createFile();
    }
    this.activeId = id;
    this.current = this._open(id);
  }

  // ------------------------------------------------------------------ 文件层

  _path(id) { return join(this.dir, `${id}.json`); }

  /** 目录里现有的对话 id（跳过 trash/ 和不是 .json 的东西） */
  _ids() {
    let names = [];
    try { names = readdirSync(this.dir); } catch { return []; }
    return names
      .filter((n) => n.toLowerCase().endsWith('.json'))
      .map((n) => n.replace(/\.json$/i, ''))
      .filter((n) => ID_RE.test(n));
  }

  _readMeta(id) {
    try {
      const raw = JSON.parse(readFileSync(this._path(id), 'utf8'));
      const messages = Array.isArray(raw.messages) ? raw.messages : [];
      return {
        id,
        title: typeof raw.title === 'string' && raw.title ? raw.title : titleFromMessages(messages, ''),
        messages,
        archived: Array.isArray(raw.archive) ? raw.archive.length : 0,
        logLines: Array.isArray(raw.log) ? raw.log.length : 0,
        createdAt: raw.createdAt || '',
        updatedAt: raw.updatedAt || raw.createdAt || '',
      };
    } catch {
      return null;               // 坏文件只跳过它，不影响其余对话
    }
  }

  _mostRecentId(ids) {
    let best = '';
    let bestAt = '';
    for (const id of ids) {
      const meta = this._readMeta(id);
      if (!meta) continue;
      const at = meta.updatedAt || '';
      if (!best || at > bestAt) { best = id; bestAt = at; }
    }
    return best;
  }

  /** 建一个空对话文件，返回它的 id（不激活） */
  _createFile(title = '') {
    const id = newConversationId(this.now());
    const c = new Conversation({ file: this._path(id), id, title, budgetTokens: this.budgetTokens, now: this.now });
    c.save();
    return id;
  }

  _open(id) {
    return new Conversation({ file: this._path(id), id, budgetTokens: this.budgetTokens, now: this.now });
  }

  /**
   * 把老的单文件历史变成第一个对话（幂等：目录里已经有对话就不做）。
   * 原文件改名成 `history.json.migrated` 留底 —— 迁移出错也还有原件。
   */
  _migrateLegacy() {
    if (!this.legacyFile || !existsSync(this.legacyFile)) return;
    if (this._ids().length > 0) return;                 // 已经有对话了，不重复迁
    let raw = null;
    try { raw = JSON.parse(readFileSync(this.legacyFile, 'utf8')); } catch { return; }
    const messages = Array.isArray(raw?.messages) ? raw.messages : [];
    if (messages.length === 0) return;                  // 空的没必要迁

    const id = newConversationId(this.now());
    const c = new Conversation({
      file: this._path(id),
      id,
      title: titleFromMessages(messages, '之前的对话'),
      budgetTokens: this.budgetTokens,
      now: this.now,
    });
    c.messages = messages;
    if (typeof raw.summary === 'string') c.summary = raw.summary;
    c.save();
    try { renameSync(this.legacyFile, `${this.legacyFile}.migrated`); } catch { /* 留底失败不影响迁移 */ }
  }

  // ------------------------------------------------------------------ 查询

  /** 对话清单（新的在前）：面板上那张表就是它 */
  list() {
    const items = [];
    for (const id of this._ids()) {
      const meta = this._readMeta(id);
      if (!meta) continue;
      items.push({
        id,
        title: meta.title || '未命名',
        messages: meta.messages.length,
        tokens: meta.messages.reduce((n, m) => n + messageTokens(m), 0),
        archived: meta.archived,
        logLines: meta.logLines,
        createdAt: meta.createdAt,
        updatedAt: meta.updatedAt,
        active: id === this.activeId,
      });
    }
    items.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
    return items;
  }

  /** 按 id 或列表序号（1-based，和面板上显示的一致）找一个对话 */
  find(idOrIndex) {
    const items = this.list();
    const s = String(idOrIndex == null ? '' : idOrIndex).trim();
    if (!s) return null;
    if (/^\d+$/.test(s)) {
      const i = Number(s);
      return (i >= 1 && i <= items.length) ? items[i - 1] : null;
    }
    return items.find((it) => it.id === s) || null;
  }

  // ------------------------------------------------------------------ 操作

  /** 切到某个对话：先把当前的存盘，再换 file 重新 load（current 引用不变） */
  activate(idOrIndex) {
    const item = this.find(idOrIndex);
    if (!item) return { ok: false, reason: 'not-found' };
    if (item.id === this.activeId) {
      return { ok: true, action: 'switch', id: item.id, title: item.title, active: true, unchanged: true };
    }
    return this._switchTo(item.id, true);
  }

  /**
   * 换当前对话。
   * saveCurrent=false 用在"删掉当前对话"时 —— 那时文件已经被移走了，
   * 再 save 一次会把刚删的文件原地复活（这个坑写在这里，别改回去）。
   */
  _switchTo(id, saveCurrent) {
    if (saveCurrent) { try { this.current.save(); } catch { /* 存不下也照样切 */ } }
    this.activeId = id;
    this.current.file = this._path(id);
    this.current.id = id;
    this.current.title = '';
    this.current.createdAt = '';
    this.current.updatedAt = '';
    this.current.messages = [];
    this.current.summary = '';
    this.current.archive = [];
    this.current.log = [];
    this.current.load();
    return { ok: true, action: 'switch', id, title: this.current.title, active: true };
  }

  create({ title = '' } = {}) {
    try { this.current.save(); } catch { /* 忽略 */ }
    const id = this._createFile(title);
    this.activeId = id;
    this.current.file = this._path(id);
    this.current.id = id;
    this.current.title = title;
    this.current.createdAt = '';
    this.current.updatedAt = '';
    this.current.messages = [];
    this.current.summary = '';
    this.current.archive = [];
    this.current.log = [];
    this.current.load();            // 读回刚写的文件，把时间戳拿回来
    return { ok: true, action: 'new', id, title: this.current.title || title, active: true };
  }

  rename(idOrIndex, title) {
    const item = this.find(idOrIndex);
    if (!item) return { ok: false, reason: 'not-found' };
    const clean = String(title == null ? '' : title).trim().slice(0, 60);
    if (!clean) return { ok: false, reason: 'empty-title' };
    if (item.id === this.activeId) {
      this.current.title = clean;
      this.current.save();
    } else {
      const c = this._open(item.id);
      c.title = clean;
      c.save();
    }
    return { ok: true, action: 'rename', id: item.id, title: clean, active: item.id === this.activeId };
  }

  /** 删除 = 移进 trash/。只剩一个时拒绝 —— 否则界面没地方可去。 */
  remove(idOrIndex) {
    const item = this.find(idOrIndex);
    if (!item) return { ok: false, reason: 'not-found' };
    if (this._ids().length <= 1) return { ok: false, reason: 'last', id: item.id, title: item.title };

    mkdirSync(this.trashDir, { recursive: true });
    const stamp = this.now().toISOString().replace(/[:.]/g, '-');
    const dest = join(this.trashDir, `${item.id}.${stamp}.json`);
    try {
      renameSync(this._path(item.id), dest);
    } catch (e) {
      return { ok: false, reason: `move failed: ${e?.message || e}` };
    }

    let next = null;
    if (item.id === this.activeId) {
      // 删的是当前这个：切到最近更新过的另一个（**不能**先 save，见 _switchTo 注释）
      const rest = this._ids();
      const nextId = this._mostRecentId(rest) || this._createFile();
      const sw = this._switchTo(nextId, false);
      next = sw.ok ? sw.id : nextId;
    }
    return { ok: true, action: 'delete', id: item.id, title: item.title, active: this.activeId, next, trashed: dest };
  }

  /** 写回"当前是哪个对话"（server 负责落到 config.json） */
  stats() {
    return {
      active: this.activeId,
      title: this.current.title,
      count: this._ids().length,
      dir: this.dir,
    };
  }

  /** 面板回放：最近 limit 行 + 是否还有更早的 */
  replay(limit = 400) {
    const n = Math.max(1, Number(limit) || 400);
    const all = this.current.log || [];
    const lines = all.length > n ? all.slice(-n) : all.slice();
    return { lines, more: Math.max(0, all.length - lines.length) };
  }
}

export { Conversation };
