// JSONL 环形账本：自扩展闭环唯一的事实来源（谁在什么时候提了什么、验过没有）。
// 环形（默认 5000 行）是硬要求而不是优化：模型会反复 propose，日志无上限最终会把
// 磁盘和 grep 一起拖死；只留最近一段就够回答"刚才那版为什么回滚"。
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

export const DEFAULT_MAX_LINES = 5000;

export function createJournal({ file = '', maxLines = DEFAULT_MAX_LINES } = {}) {
  let lines = 0;
  if (file && existsSync(file)) lines = readFileSync(file, 'utf8').split('\n').filter(Boolean).length;

  function trim() {
    const all = readFileSync(file, 'utf8').split('\n').filter(Boolean);
    const keep = all.slice(-maxLines);
    writeFileSync(file, keep.join('\n') + (keep.length ? '\n' : ''), 'utf8');
    lines = keep.length;
  }

  function log(event) {
    const row = { t: new Date().toISOString(), ...(event || {}) };
    if (!file) return row;
    try {
      mkdirSync(dirname(file), { recursive: true });
      appendFileSync(file, JSON.stringify(row) + '\n', 'utf8');
    } catch {
      return row;   // 账本写不进去不能反过来阻断闭环
    }
    if (++lines > maxLines) trim();
    return row;
  }

  function tail(n = 50) {
    if (!file || !existsSync(file)) return [];
    return readFileSync(file, 'utf8')
      .split('\n')
      .filter(Boolean)
      .slice(-n)
      .map((line) => { try { return JSON.parse(line); } catch { return { raw: line }; } });
  }

  return { log, tail, count: () => lines, file, maxLines };
}
