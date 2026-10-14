// 色值 + 场景记忆库
//
// 存"用过什么颜色、在什么场景下用的、为什么"，供 AI 按需检索。
// 落盘在 bridge/data/colors.json，纯文本，可手工编辑。

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';

export class ColorBank {
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

  static normHex(hex) {
    if (typeof hex !== 'string') return null;
    let s = hex.trim().replace(/^#/, '').toUpperCase();
    if (s.length === 3) s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2];
    if (s.length === 8) s = s.slice(0, 6);
    if (!/^[0-9A-F]{6}$/.test(s)) return null;
    return '#' + s;
  }

  remember({ hex, scene, tags = [], note = '', sprite = '' }) {
    const h = ColorBank.normHex(hex);
    if (!h) return { error: `bad colour format: ${hex} (expected #RRGGBB)` };
    if (!scene) return { error: 'missing scene: describe where this colour is used' };

    const tagList = Array.isArray(tags) ? tags.filter(Boolean).map(String) : [];
    const existing = this.entries.find(
      (e) => e.hex === h && e.scene === scene && e.sprite === sprite,
    );
    const now = new Date().toISOString();
    if (existing) {
      existing.tags = Array.from(new Set([...(existing.tags || []), ...tagList]));
      if (note) existing.note = note;
      existing.updatedAt = now;
      existing.usedCount = (existing.usedCount || 1) + 1;
      this.save();
      return { ok: true, updated: true, entry: existing };
    }

    const entry = { hex: h, scene, tags: tagList, note, sprite, createdAt: now, usedCount: 1 };
    this.entries.push(entry);
    this.save();
    return { ok: true, entry };
  }

  search({ query = '', hex = '', tag = '', limit = 12 }) {
    let list = this.entries;
    const h = hex ? ColorBank.normHex(hex) : null;
    if (h) list = list.filter((e) => e.hex === h);
    if (tag) {
      const t = String(tag).toLowerCase();
      list = list.filter((e) => (e.tags || []).some((x) => String(x).toLowerCase().includes(t)));
    }
    if (query) {
      const q = String(query).toLowerCase();
      list = list.filter(
        (e) =>
          e.scene.toLowerCase().includes(q) ||
          (e.note || '').toLowerCase().includes(q) ||
          (e.tags || []).some((x) => String(x).toLowerCase().includes(q)) ||
          e.hex.toLowerCase().includes(q),
      );
    }
    const out = list
      .slice()
      .sort((a, b) => String(b.updatedAt || b.createdAt).localeCompare(String(a.updatedAt || a.createdAt)))
      .slice(0, Math.max(1, Math.min(50, Number(limit) || 12)));
    return { total: list.length, returned: out.length, entries: out };
  }
}
