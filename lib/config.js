/** 插件配置、路径判定、备份。零 dsh 依赖，可单测。
 *  优先级：cordis 传入的 config > config.json > 默认值。
 *  路径一律按需计算（homeDir() 每次读环境变量），这样测试能把插件"家目录"指到临时目录。 */
import {
  copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync
} from 'node:fs';
import { basename, dirname, isAbsolute, join, normalize, relative, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

/** 插件自己的家目录；测试用 DSH_ASEPRITE_HOME 改写它，避免动真配置。 */
export function homeDir() {
  return process.env.DSH_ASEPRITE_HOME || join(homedir(), '.dsh', 'dsh-plugin-aseprite');
}
export function configPath() {
  return join(homeDir(), 'config.json');
}
/** Lua 模块根 = 仓库根（lib/ 的上一层）。领域层就在本仓库 lib/ 下，
 *  所以 `<root>/?.lua` 能解析 `require("lib.ops")` —— 不再 vendored、也不依赖任何外部 checkout。 */
export function luaRoot() {
  return fileURLToPath(new URL('../', import.meta.url));
}

export function defaults() {
  return {
    aseprite: 'D:/PraticleTool/Aseprite/aseprite.exe',
    luaRoot: luaRoot(),
    workspace: join(homeDir(), 'workspace'),
    exportDir: '',               // 空 = <workspace>/_export
    allowOutside: false
  };
}

function readFile() {
  try { return JSON.parse(readFileSync(configPath(), 'utf8')); } catch { return {}; }
}

/** 老配置里的键叫 extensionDir；迁移必须在合并默认值之前做，否则默认的 luaRoot 会把它挡住。 */
function migrateLuaRoot(obj) {
  if (obj && obj.extensionDir && !obj.luaRoot) obj.luaRoot = obj.extensionDir;
  if (obj) delete obj.extensionDir;
  return obj;
}

export function loadConfig(overrides = {}) {
  const merged = Object.assign({}, defaults(), migrateLuaRoot(readFile()), migrateLuaRoot(Object.assign({}, overrides || {})));
  merged.aseprite = String(merged.aseprite || defaults().aseprite);
  merged.luaRoot = String(merged.luaRoot || luaRoot()).replace(/[\\/]+$/, '');
  merged.workspace = normalize(String(merged.workspace || defaults().workspace));
  merged.exportDir = normalize(String(merged.exportDir || join(merged.workspace, '_export')));
  merged.allowOutside = merged.allowOutside === true;
  return merged;
}

export function saveConfig(patch) {
  const cur = readFile();
  const next = Object.assign({}, cur, patch);
  mkdirSync(dirname(configPath()), { recursive: true });
  writeFileSync(configPath(), JSON.stringify(next, null, 2) + '\n', 'utf8');
  return loadConfig();
}

export function ensureWorkspace(cfg) {
  for (const d of [cfg.workspace, cfg.exportDir]) {
    try { mkdirSync(d, { recursive: true }); } catch {}
  }
}

/** 相对路径按 workspace 解析；绝对路径按 allowOutside 判定。 */
export function resolvePath(cfg, p, { mustBeInWorkspace = true } = {}) {
  const raw = String(p || '').trim();
  if (!raw) return { ok: false, error: 'empty path' };
  const abs = isAbsolute(raw) ? normalize(raw) : resolve(cfg.workspace, raw);
  if (!mustBeInWorkspace) return { ok: true, path: abs };
  const rel = relative(cfg.workspace, abs);
  const inside = rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
  if (!inside && !cfg.allowOutside) {
    return {
      ok: false,
      error: 'path is outside the workspace: ' + abs + '\nworkspace: ' + cfg.workspace +
             '\nset allowOutside=true in ' + configPath() + ' if this is intentional.'
    };
  }
  return { ok: true, path: abs, outside: !inside };
}

export function defaultExportPath(cfg, srcPath) {
  const base = srcPath.split(/[\\/]/).pop() || 'out';
  const stem = base.replace(/\.[^.]+$/, '');
  return join(cfg.exportDir, stem + '.png');
}

export function describe(cfg) {
  return [
    'aseprite   ' + cfg.aseprite + (existsSync(cfg.aseprite) ? '' : '  (NOT FOUND)'),
    'luaRoot    ' + cfg.luaRoot,
    'workspace  ' + cfg.workspace,
    'exportDir  ' + cfg.exportDir,
    'allowOutside ' + cfg.allowOutside,
    'config     ' + configPath()
  ].join('\n');
}

/* ------------------------------------------------------------------ *
 * 备份：覆盖前先留一份，失败即中止（没有备份的写入等于没有后悔药）
 * ------------------------------------------------------------------ */

export const BACKUP_KEEP = 10;

/** 备份文件名前缀：YYYYMMDD-HHmmss-SSS，字典序 == 时间序，便于按名字裁剪旧备份。 */
export function stamp(d = new Date()) {
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-` +
         `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}-${p(d.getMilliseconds(), 3)}`;
}

function safeSegment(s) {
  return s.replace(/[^A-Za-z0-9._-]+/g, '_').slice(0, 120) || 'path';
}

/** 备份落到 <workspace>/_backup/<源相对路径>/<时间戳>_<原名>。工作区外的源压到 _outside/ 下。 */
export function backupPlan(cfg, srcPath) {
  const abs = normalize(srcPath);
  const rel = relative(cfg.workspace, abs);
  const inside = rel !== '' && !rel.startsWith('..') && !isAbsolute(rel);
  const dir = inside
    ? join(cfg.workspace, '_backup', dirname(rel))
    : join(cfg.workspace, '_backup', '_outside', safeSegment(abs.replace(/[:\\/]+/g, '_')));
  return { dir, name: basename(abs) };
}

/** 备份一个文件。源不存在时返回 skipped（没有可丢的东西）。
 *  复制失败 / 大小不符会抛错 —— 调用方必须中止后续写入。 */
export function backupFile(cfg, srcPath, now = new Date()) {
  if (!existsSync(srcPath)) return { skipped: true, reason: 'source does not exist yet' };
  const { dir, name } = backupPlan(cfg, srcPath);
  mkdirSync(dir, { recursive: true });
  const prefix = stamp(now);
  let target = join(dir, prefix + '_' + name);
  for (let n = 1; existsSync(target); n++) target = join(dir, prefix + '-' + n + '_' + name);
  copyFileSync(srcPath, target);   // 抛错 = 备份失败，调用方中止
  if (statSync(srcPath).size !== statSync(target).size) {
    throw new Error('backup is incomplete: ' + target);
  }
  const pruned = pruneBackups(dir, name, BACKUP_KEEP);
  return { skipped: false, path: target, pruned };
}

/** 同一源文件只留最新的 keep 份（按文件名前缀排序）。删不掉只记数，不影响本次操作。 */
export function pruneBackups(dir, baseName, keep = BACKUP_KEEP) {
  const suffix = '_' + baseName;
  let files;
  try { files = readdirSync(dir); } catch { return 0; }
  const mine = files.filter((f) => f.length > suffix.length && f.endsWith(suffix)).sort();
  const stale = mine.slice(0, Math.max(0, mine.length - keep));
  let removed = 0;
  for (const f of stale) {
    try { unlinkSync(join(dir, f)); removed++; } catch {}
  }
  return removed;
}
