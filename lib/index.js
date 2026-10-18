/** dsh-plugin-aseprite -- Aseprite 能力接入 DSH（batch 路线，Aseprite 侧零安装）。
 *  工作区/导出区/备份见 lib/config.js；所有路径先经 resolvePath 判定，工作区外默认拒绝。
 *  领域层 lib/ops.lua 就在本仓库里；lib/ops.manifest.json 由 test/gen-manifest.mjs 生成。 */
import { readdirSync, statSync, appendFileSync } from 'node:fs';
import { join, extname } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import { defineTool } from '@deepseek-ai/dsh-tools';
import { SCRIPTS, runLua, applyScript, exportScript, readManifest } from './runner.js';
import { applyDescription, manifestText, STALE_HINT } from './opsinfo.js';
import { createApi } from './api.js';
import { createEcho, registerRoutes } from './routes.js';
import {
  configPath, defaultExportPath, describe, ensureWorkspace, loadConfig, resolvePath, saveConfig, backupFile
} from './config.js';

export const name = 'dsh-plugin-aseprite';

const LOG = join(tmpdir(), 'dsh-plugin-aseprite.log');
const note = (l) => { try { appendFileSync(LOG, new Date().toISOString() + ' ' + l + '\n'); } catch {} };
const textOut = (t) => [{ type: 'text', text: String(t == null ? '' : t) }];
const outShape = { schema: { type: 'object', additionalProperties: true }, render: (a, v) => textOut(v && v.text) };

export function apply(ctx, config = {}) {
  const cfg = loadConfig(config);
  ensureWorkspace(cfg);

  let manifest = [];
  try { manifest = readManifest(cfg.luaRoot); }
  catch (e) { note('manifest load failed: ' + e.message); }
  const opsText = manifestText(manifest);
  note('apply: workspace=' + cfg.workspace + ' export=' + cfg.exportDir + ' ops=' + manifest.length);

  // P2 面板：HTTP API + 媒体流 + 操作回显（工具面不受影响）
  //
  // 服务是后注册的：插件可能先于 webServer/connection 挂载（实测两种启动顺序都出现过），
  // 所以必须用 ctx.inject 等到服务就绪再挂路由 —— 直接 ctx.get/属性访问会拿到 undefined 或抛错。
  try {
    let echoImpl = () => Promise.resolve({ echoed: false, reason: 'agents service not ready yet' });
    if (typeof ctx.inject === 'function') {
      try {
        ctx.inject(['agents'], (actx) => { echoImpl = createEcho(actx, note); });
      } catch (e) { note('agents inject failed: ' + (e && e.message)); }
    } else {
      echoImpl = createEcho(ctx, note);
    }
    const echo = (text, sessionId) => echoImpl(text, sessionId);

    const wire = (wctx) => {
      try {
        const api = createApi(wctx, cfg, manifest, { note, echo });
        const disposers = registerRoutes(wctx, api, cfg, { note });
        for (const dispose of disposers) {
          try {
            if (typeof wctx.effect === 'function') wctx.effect(() => dispose, 'dsh-plugin-aseprite: panel routes');
            else note('ctx.effect unavailable; route disposer dropped');
          } catch (e) { note('route effect failed: ' + e.message); }
        }
        note('panel routes registered: ' + disposers.length);
      } catch (e) {
        note('panel routes failed: ' + (e && e.message));
      }
    };

    if (typeof ctx.inject === 'function') {
      ctx.inject(['webServer', 'connection'], wire);
      note('panel wiring deferred until webServer/connection are ready');
    } else {
      wire(ctx);
    }
  } catch (e) {
    note('panel wiring failed: ' + (e && e.message));
  }

  ctx.tools.register(defineTool({
    name: 'aseprite_config',
    description: 'Read or change this plugin settings: workspace root, export directory, allowOutside, aseprite path, Lua module root. Call with no arguments to read.',
    parameters: {
      workspace: { type: 'string', required: false, description: 'New workspace root (absolute)' },
      exportDir: { type: 'string', required: false, description: 'New export directory (absolute)' },
      allowOutside: { type: 'boolean', required: false, description: 'Allow paths outside the workspace' },
      aseprite: { type: 'string', required: false, description: 'Absolute path to aseprite.exe' },
      extensionDir: { type: 'string', required: false, description: 'DEPRECATED alias of luaRoot' },
      luaRoot: { type: 'string', required: false, description: 'Absolute path to the Lua module root (defaults to this plugin root)' }
    },
    output: outShape,
    execute: async (args) => {
      const patch = {};
      for (const k of ['workspace', 'exportDir', 'aseprite', 'luaRoot']) {
        if (typeof args[k] === 'string' && args[k].trim()) patch[k] = args[k].trim();
      }
      if (typeof args.extensionDir === 'string' && args.extensionDir.trim() && !patch.luaRoot) {
        patch.luaRoot = args.extensionDir.trim();
      }
      if (typeof args.allowOutside === 'boolean') patch.allowOutside = args.allowOutside;
      if (Object.keys(patch).length) {
        const next = saveConfig(patch);
        ensureWorkspace(next);
        Object.assign(cfg, next);
        return { text: 'saved to ' + configPath() + '\n' + describe(cfg) };
      }
      return { text: describe(cfg) };
    }
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_status',
    description: 'Check the local Aseprite installation, the bundled op count and the current workspace settings. Start here when something looks wrong.',
    parameters: {},
    output: outShape,
    execute: async () => {
      const st = await runLua(cfg, SCRIPTS.status);
      return {
        text: (st.ok ? 'Aseprite ' + st.text : 'Aseprite unavailable: ' + st.text) +
              '\nops available: ' + manifest.length +
              '\nops source   : ' + cfg.luaRoot + '/lib/ops.lua' +
              '\n' + describe(cfg)
      };
    }
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_ops',
    description: 'List the canvas operations that can be applied, with their parameters and defaults.',
    parameters: {},
    output: outShape,
    execute: async () => ({ text: opsText || 'no op manifest found (run test/gen-manifest.mjs)' })
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_ls',
    description: 'List sprite files (.ase/.aseprite/.png) inside the workspace, so you can pick a file without asking the user for a path.',
    parameters: { dir: { type: 'string', required: false, description: 'Subdirectory inside the workspace; defaults to the workspace root' } },
    output: outShape,
    execute: async (args) => {
      const rp = resolvePath(cfg, args.dir || '.');
      if (!rp.ok) return { text: 'error: ' + rp.error };
      try {
        const rows = readdirSync(rp.path)
          .filter((f) => ['.ase', '.aseprite', '.png'].includes(extname(f).toLowerCase()))
          .map((f) => {
            const st = statSync(join(rp.path, f));
            return f + '  ' + st.size + 'B';
          });
        return { text: rows.length ? rp.path + '\n' + rows.join('\n') : rp.path + '\n(no sprite files)' };
      } catch (e) {
        return { text: 'error: ' + e.message };
      }
    }
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_apply',
    description: applyDescription(manifest),
    parameters: {
      file: { type: 'string', required: true, description: 'Source file; relative paths resolve against the workspace' },
      out: { type: 'string', required: false, description: 'Output file; defaults to overwriting the source' },
      ops: { type: 'array', required: true, description: 'Operations in order, e.g. [{"op":"contrast","amount":1.5}]', items: { type: 'object', additionalProperties: true } }
    },
    output: outShape,
    execute: async (args) => {
      const src = resolvePath(cfg, args.file);
      if (!src.ok) return { text: 'error: ' + src.error };
      const dst = args.out ? resolvePath(cfg, args.out) : src;
      if (!dst.ok) return { text: 'error: ' + dst.error };
      const ops = Array.isArray(args.ops) ? args.ops : [];
      if (!ops.length) return { text: 'error: ops is empty' };

      // 覆盖前备份；备份失败 -> 什么都不改
      let backup = null;
      try {
        backup = backupFile(cfg, dst.path);
      } catch (e) {
        return { text: 'aborted: could not back up the existing file, nothing was changed.\n' + e.message };
      }
      if (backup && backup.skipped === false) note('backup: ' + backup.path);

      const r = await runLua(cfg, applyScript({ file: src.path, out: dst.path, ops }));
      const lines = [(r.ok ? 'ok: ' : 'failed: ') + r.text, 'file: ' + dst.path];
      if (backup && backup.path) lines.push('backup: ' + backup.path);
      if (r.ok) lines.push(STALE_HINT.trim());
      return { text: lines.join('\n') };
    }
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_export',
    description: 'Export a sprite file to another format without editing it. Without out, the result goes to the export directory.',
    parameters: {
      file: { type: 'string', required: true, description: 'Source file; relative paths resolve against the workspace' },
      out: { type: 'string', required: false, description: 'Output file; defaults to <exportDir>/<stem>.png' }
    },
    output: outShape,
    execute: async (args) => {
      const src = resolvePath(cfg, args.file);
      if (!src.ok) return { text: 'error: ' + src.error };
      const outPath = args.out ? null : defaultExportPath(cfg, src.path);
      const dst = args.out ? resolvePath(cfg, args.out) : { ok: true, path: outPath };
      if (!dst.ok) return { text: 'error: ' + dst.error };
      const r = await runLua(cfg, exportScript({ file: src.path, out: dst.path }));
      return { text: (r.ok ? 'ok: ' : 'failed: ') + r.text + '\nout: ' + dst.path };
    }
  }));

  ctx.tools.register(defineTool({
    name: 'aseprite_open',
    description: 'Open a sprite file in the Aseprite GUI so the user can look at the result.',
    parameters: { file: { type: 'string', required: true, description: 'File to open; relative paths resolve against the workspace' } },
    output: outShape,
    execute: async (args) => {
      const rp = resolvePath(cfg, args.file);
      if (!rp.ok) return { text: 'error: ' + rp.error };
      try {
        const child = spawn(cfg.aseprite, [rp.path], { detached: true, stdio: 'ignore', windowsHide: false });
        child.on('error', (e) => note('open failed: ' + e.message));
        child.unref();
        return { text: 'opened in Aseprite: ' + rp.path };
      } catch (e) {
        return { text: 'error: ' + e.message };
      }
    }
  }));

  note('registered 7 tools');
}
