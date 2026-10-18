/** P2: 面板与宿主的桥（HTTP JSON API + 图片流）。
 *  客户端只认这些方法；工具面（7 个 defineTool）保持不变。
 *  设计约束：所有路径先过 resolvePath（工作区外默认拒绝），图片流也只放行允许的目录。 */
import { createReadStream, existsSync, mkdirSync, readdirSync, statSync } from 'node:fs';
import { basename, extname, isAbsolute, join, relative } from 'node:path';
import { runLua, applyScript, exportScript } from './runner.js';
import { backupFile, configPath, defaultExportPath, resolvePath } from './config.js';

const SPRITE_EXT = ['.ase', '.aseprite', '.png'];
const PREVIEW_DIR = '_preview';

const MIME = {
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ase': 'application/octet-stream',
  '.aseprite': 'application/octet-stream'
};

/** 由 cfg 派生的只读路径。导出区可配置，预览固定在工作区内。 */
export function paths(cfg) {
  return {
    workspace: cfg.workspace,
    exportDir: cfg.exportDir,
    previewDir: join(cfg.workspace, PREVIEW_DIR)
  };
}

/** 目录内的精灵文件，按名字排序。 */
export function listSpriteFiles(cfg, dir) {
  const rp = resolvePath(cfg, dir || '.');
  if (!rp.ok) throw new Error(rp.error);
  const rows = readdirSync(rp.path)
    .filter((f) => SPRITE_EXT.includes(extname(f).toLowerCase()))
    .map((f) => {
      const st = statSync(join(rp.path, f));
      return { name: f, size: st.size, mtime: st.mtimeMs };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
  return { dir: rp.path, files: rows };
}

/** 预览图落点：<workspace>/_preview/<stem>-<短哈希>.png（避免同名覆盖、避免污染导出区）。 */
export function previewTarget(cfg, file) {
  const rel = relative(cfg.workspace, file).replace(/[\\/]+/g, '/');
  const stem = (basename(file).replace(/\.[^.]+$/, '') || 'sprite').replace(/[^A-Za-z0-9._-]+/g, '_');
  let h = 0;
  for (let i = 0; i < rel.length; i++) h = (h * 31 + rel.charCodeAt(i)) | 0;
  const tag = (h >>> 0).toString(36).slice(0, 6);
  return join(cfg.workspace, PREVIEW_DIR, stem + '-' + tag + '.png');
}

/** 面板使用的 API 表。ctx 只用来做 admission / echo，可在测试里注入假的。 */
export function createApi(ctx, cfg, manifest, opts = {}) {
  const note = opts.note || (() => {});
  const echo = opts.echo || (() => Promise.resolve({ echoed: false, reason: 'echo disabled' }));

  const api = {
    async state() {
      let files = [];
      let listError = null;
      try { files = listSpriteFiles(cfg, '.').files; } catch (e) { listError = e.message; }
      return {
        workspace: cfg.workspace,
        exportDir: cfg.exportDir,
        config: configPath(),
        aseprite: existsSync(cfg.aseprite),
        ops: manifest,
        files,
        listError
      };
    },

    async ls(args) {
      return listSpriteFiles(cfg, args.dir);
    },

    async preview({ file }) {
      const rp = resolvePath(cfg, file);
      if (!rp.ok) throw new Error(rp.error);
      if (!existsSync(rp.path)) throw new Error('no such file: ' + rp.path);
      // 源就是 PNG：直接给媒体路由，不绕 Aseprite
      if (extname(rp.path).toLowerCase() === '.png') return { path: rp.path, via: 'png' };
      const out = previewTarget(cfg, rp.path);
      mkdirSync(join(cfg.workspace, PREVIEW_DIR), { recursive: true });
      const r = await runLua(cfg, exportScript({ file: rp.path, out }));
      if (!r.ok) throw new Error(r.text);
      return { path: out, via: 'export' };
    },

    async apply({ file, out, ops, op, params, sessionId }) {
      const src = resolvePath(cfg, file);
      if (!src.ok) throw new Error(src.error);
      const dst = out ? resolvePath(cfg, out) : src;
      if (!dst.ok) throw new Error(dst.error);
      const list = Array.isArray(ops) && ops.length ? ops : (op ? [Object.assign({ op }, params || {})] : []);
      if (!list.length) throw new Error('no operations given');

      // 覆盖前备份；失败即中止（DESIGN §4）
      let backup = null;
      try { backup = backupFile(cfg, dst.path); }
      catch (e) { return { ok: false, error: 'backup failed, nothing changed: ' + e.message }; }

      const r = await runLua(cfg, applyScript({ file: src.path, out: dst.path, ops: list }));
      if (!r.ok) return { ok: false, error: r.text, backup: backup && backup.path };

      const rest = list.map((o) => o.op || o.type || o.name).join(' + ');
      const text = rest + ' -> ' + r.text + ' (' + dst.path + ')';
      const inject = await echo('面板操作：' + text + '。画布已更新，无需重复执行。', sessionId);
      return { ok: true, text: r.text, ops: rest, file: dst.path, backup: backup && backup.path, echo: inject };
    },

    async export({ file, out, sessionId }) {
      const src = resolvePath(cfg, file);
      if (!src.ok) throw new Error(src.error);
      const target = out ? resolvePath(cfg, out) : { ok: true, path: defaultExportPath(cfg, src.path) };
      if (!target.ok) throw new Error(target.error);
      mkdirSync(join(cfg.exportDir), { recursive: true });
      const r = await runLua(cfg, exportScript({ file: src.path, out: target.path }));
      if (!r.ok) throw new Error(r.text);
      const inject = await echo('面板操作：导出 ' + target.path + '。', sessionId);
      return { ok: true, out: target.path, text: r.text, echo: inject };
    },

    async open({ file }) {
      const rp = resolvePath(cfg, file);
      if (!rp.ok) throw new Error(rp.error);
      const { spawn } = await import('node:child_process');
      const child = spawn(cfg.aseprite, [rp.path], { detached: true, stdio: 'ignore', windowsHide: false });
      child.on('error', (e) => note('open failed: ' + e.message));
      child.unref();
      return { ok: true, file: rp.path };
    }
  };
  return api;
}

/** 媒体白名单：工作区 / 导出区内的文件才允许流出去。 */
export function mediaAllowed(cfg, absPath) {
  const p = String(absPath || '');
  if (!p || !isAbsolute(p)) return false;
  const roots = [cfg.workspace, cfg.exportDir].filter(Boolean);
  for (const root of roots) {
    const rel = relative(root, p);
    if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) return true;
  }
  return false;
}

export function contentType(file) {
  return MIME[extname(file).toLowerCase()] || 'application/octet-stream';
}

/** 用假 ctx 调 API（测试与面板共用）。 */
export async function handleApi(api, method, args) {
  const fn = api[method];
  if (typeof fn !== 'function') throw new Error('unknown api method: ' + method);
  return fn(args || {});
}
