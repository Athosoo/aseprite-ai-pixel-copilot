/** Aseprite 批处理执行器：不依赖任何 dsh 包，可脱离宿主单测。
 *  约定：Lua 脚本把要返回的内容赋给 OUT（字符串），出错时自动抛出。
 *  Lua 模块根 = cfg.luaRoot（默认就是本仓库根，lib/ops.lua 在这里）。 */
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

/** 经 JSON.stringify 产出 Lua 可用的字符串字面量（转义规则对 Lua 5.4 同样合法）。 */
export function luaStr(s) {
  return JSON.stringify(String(s));
}

export function runLua(cfg, luaBody, timeoutMs = 60000) {
  const dir = mkdtempSync(join(tmpdir(), 'ase-'));
  const resultPath = join(dir, 'result.txt');
  const scriptPath = join(dir, 'run.lua');
  const head =
    'local __ok, __err = pcall(function()\n' +
    'package.path = package.path .. ";" .. ' + luaStr(cfg.luaRoot + '/?.lua') + '\n';
  const tail =
    'end)\n' +
    'local f = io.open(' + luaStr(resultPath) + ', "w")\n' +
    'if __ok then f:write("OK\\n" .. tostring(OUT or "")) else f:write("ERR\\n" .. tostring(__err)) end\n' +
    'f:close()\n';
  writeFileSync(scriptPath, head + luaBody + tail, 'utf8');

  return new Promise((resolve) => {
    const child = spawn(cfg.aseprite, ['-b', '--script', scriptPath], { stdio: 'ignore', windowsHide: true });
    const timer = setTimeout(() => { try { child.kill(); } catch {} }, timeoutMs);
    child.on('error', (e) => { clearTimeout(timer); resolve({ ok: false, text: 'spawn failed: ' + e.message }); });
    child.on('exit', (code) => {
      clearTimeout(timer);
      if (!existsSync(resultPath)) return resolve({ ok: false, text: 'no result (aseprite exit ' + code + ')' });
      const raw = readFileSync(resultPath, 'utf8');
      const nl = raw.indexOf('\n');
      const head2 = nl < 0 ? raw : raw.slice(0, nl);
      const body = nl < 0 ? '' : raw.slice(nl + 1);
      return resolve({ ok: head2.trim() === 'OK', text: body });
    });
  });
}

export const SCRIPTS = {
  status: 'OUT = app.version\n'
};

/** 读算子清单（由 test/gen-manifest.mjs 从 lib/ops.lua 的 ops.manifest() 生成）。 */
export function readManifest(luaRoot) {
  return JSON.parse(readFileSync(join(luaRoot, 'lib', 'ops.manifest.json'), 'utf8'));
}

/** 把 JS 值序列化成 Lua 字面量（只支持 JSON 值域，够用且安全）。 */
export function toLua(v, depth = 0) {
  if (depth > 8) throw new Error('too deep');
  if (v === null || v === undefined) return 'nil';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return Number.isFinite(v) ? String(v) : 'nil';
  if (typeof v === 'string') return luaStr(v);
  if (Array.isArray(v)) return '{' + v.map((x) => toLua(x, depth + 1)).join(',') + '}';
  const parts = Object.keys(v).map((k) => '[' + luaStr(k) + ']=' + toLua(v[k], depth + 1));
  return '{' + parts.join(',') + '}';
}

/** 在文件上跑一串算子，保存到 out。 */
export function applyScript({ file, out, ops }) {
  // ops.lua 读的是 op.op（或 op.type），这里接受更自然的 name 并归一化
  const norm = (ops || []).map((o) => {
    const name = o.op || o.type || o.name;
    const rest = Object.assign({}, o);
    delete rest.name;
    return Object.assign({ op: name }, rest);
  });
  const opsLua = toLua(norm);
  return [
    'local RESULT_FILE = ' + luaStr(file),
    'local OUT_FILE = ' + luaStr(out),
    'local spr = app.open(RESULT_FILE)',
    'if not spr then error("cannot open " .. RESULT_FILE) end',
    'local opsMod = require("lib.ops")',
    'local list = ' + opsLua,
    'local cels = opsMod.resolveCels(spr, 1, nil)',
    'if not cels then error("no cel on frame 1") end',
    'local rep = opsMod.run(list, "plugin", cels)',
    'spr:saveAs(OUT_FILE)',
    'OUT = "changed=" .. tostring(rep.changed or 0)',
    ''
  ].join('\n');
}

export function exportScript({ file, out }) {
  return [
    'local spr = app.open(' + luaStr(file) + ')',
    'if not spr then error("cannot open " .. ' + luaStr(file) + ') end',
    'spr:saveAs(' + luaStr(out) + ')',
    'OUT = "saved " .. ' + luaStr(out) + ' .. " (" .. spr.width .. "x" .. spr.height .. ")"',
    ''
  ].join('\n');
}
