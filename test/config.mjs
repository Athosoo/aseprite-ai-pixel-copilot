/** 纯逻辑单测：工作区/导出区/路径判定/备份（不需要 Aseprite）。 */
import { strict as assert } from 'node:assert';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import {
  BACKUP_KEEP, backupFile, backupPlan, configPath, defaultExportPath, describe, ensureWorkspace,
  homeDir, loadConfig, luaRoot, pruneBackups, resolvePath, saveConfig, stamp
} from '../lib/config.js';

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); pass++; console.log('  ok   ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '   <- ' + e.message); }
}

// 把插件的"家目录"指到临时目录 —— 测试绝不碰真配置
const TMP_HOME = mkdtempSync(join(tmpdir(), 'ase-plugin-home-'));
process.env.DSH_ASEPRITE_HOME = TMP_HOME;

const cfg = loadConfig();
ensureWorkspace(cfg);

console.log('== 默认值 ==');
check('家目录跟着 DSH_ASEPRITE_HOME 走', () => assert.equal(homeDir(), TMP_HOME));
check('workspace 默认在 <home>/workspace', () => assert.equal(cfg.workspace, join(TMP_HOME, 'workspace')));
check('exportDir 默认是 workspace/_export', () => assert.equal(cfg.exportDir, join(cfg.workspace, '_export')));
check('allowOutside 默认 false', () => assert.equal(cfg.allowOutside, false));
check('luaRoot 默认是仓库根（lib/ops.lua 所在处）', () => assert.equal(cfg.luaRoot, luaRoot().replace(/[\\/]+$/, '')));
check('lib/ops.lua 真的在 luaRoot 下', () => assert.ok(existsSync(join(cfg.luaRoot, 'lib', 'ops.lua'))));
check('旧配置键 extensionDir 会被迁移成 luaRoot', () => {
  const legacy = loadConfig({ extensionDir: 'D:/old/place' });
  assert.equal(legacy.luaRoot, 'D:/old/place');
  assert.equal(legacy.extensionDir, undefined);
});
check('工作区 / 导出区目录被创建', () => assert.ok(existsSync(cfg.workspace) && existsSync(cfg.exportDir)));

console.log('== 路径判定 ==');
check('相对路径解析到工作区内', () => {
  const r = resolvePath(cfg, 'art/pic.ase');
  assert.equal(r.ok, true);
  assert.ok(r.path.startsWith(cfg.workspace));
});
check('工作区内的绝对路径通过', () => assert.equal(resolvePath(cfg, join(cfg.workspace, 'x.ase')).ok, true));
check('工作区外默认被拒绝', () => {
  const r = resolvePath(cfg, 'C:/Windows/evil.ase');
  assert.equal(r.ok, false);
  assert.match(r.error, /outside the workspace/);
});
check('空路径报错', () => assert.equal(resolvePath(cfg, '').ok, false));
check('打开 allowOutside 后放行并标 outside', () => {
  const c2 = Object.assign({}, cfg, { allowOutside: true });
  const r = resolvePath(c2, 'C:/Windows/evil.ase');
  assert.equal(r.ok, true);
  assert.equal(r.outside, true);
});

console.log('== 默认导出路径 ==');
check('导出到 exportDir 且同名换成 png', () => {
  const p = defaultExportPath(cfg, join(cfg.workspace, 'sub', 'hero.aseprite'));
  assert.ok(p.startsWith(cfg.exportDir));
  assert.ok(p.endsWith('hero.png'));
});

console.log('== 配置可写可读 ==');
check('saveConfig 落盘并被 loadConfig 读回', () => {
  const ws = join(TMP_HOME, 'other-ws');
  const next = saveConfig({ workspace: ws });
  assert.equal(next.workspace, ws);
  assert.equal(loadConfig().workspace, ws);
  assert.equal(configPath(), join(TMP_HOME, 'config.json'));
  saveConfig({ workspace: cfg.workspace });   // 还原
});
check('describe 里带出配置路径', () => assert.ok(describe(cfg).includes(configPath())));

console.log('== 备份 ==');
const artDir = join(cfg.workspace, 'art');
mkdirSync(artDir, { recursive: true });
const srcFile = join(artDir, 'hero.ase');
writeFileSync(srcFile, 'original-bytes');

check('备份落在 <workspace>/_backup/<相对目录>/ 下', () => {
  const plan = backupPlan(cfg, srcFile);
  assert.equal(plan.dir, join(cfg.workspace, '_backup', 'art'));
  assert.equal(plan.name, 'hero.ase');
});
check('备份真的生成且内容一致', () => {
  const b = backupFile(cfg, srcFile);
  assert.equal(b.skipped, false);
  assert.ok(existsSync(b.path), b.path);
  assert.equal(readFileSync(b.path, 'utf8'), 'original-bytes');
});
check('源文件不存在时不备份（没什么可丢的）', () => {
  const b = backupFile(cfg, join(artDir, 'nope.ase'));
  assert.equal(b.skipped, true);
});
check('时间戳字典序 == 时间序', () => {
  const a = stamp(new Date(2026, 0, 2, 3, 4, 5, 6));
  const b = stamp(new Date(2026, 0, 2, 3, 4, 5, 7));
  assert.ok(a < b, a + ' vs ' + b);
});
check('同一源留最新的 ' + BACKUP_KEEP + ' 份', () => {
  const dir = join(cfg.workspace, '_backup', 'art');
  for (let i = 0; i < 12; i++) {
    // 用假时间造 12 份，就能精确验证裁剪顺序
    backupFile(cfg, srcFile, new Date(2026, 5, 1, 0, 0, 0, i));
  }
  const mine = readdirSync(dir).filter((f) => f.endsWith('_hero.ase'));
  assert.equal(mine.length, BACKUP_KEEP, mine.length);
  assert.ok(mine.includes(stamp(new Date(2026, 5, 1, 0, 0, 0, 11)) + '_hero.ase'), 'latest kept');
  assert.ok(!mine.includes(stamp(new Date(2026, 5, 1, 0, 0, 0, 0)) + '_hero.ase'), 'oldest pruned');
});
check('pruneBackups 只动同名源，别的源保留', () => {
  const dir = join(cfg.workspace, '_backup', 'art');
  writeFileSync(join(dir, '20260101-000000-000_other.ase'), 'x');
  pruneBackups(dir, 'hero.ase', 3);
  assert.ok(existsSync(join(dir, '20260101-000000-000_other.ase')));
  assert.equal(readdirSync(dir).filter((f) => f.endsWith('_hero.ase')).length, 3);
});
check('工作区外的源压到 _backup/_outside 下', () => {
  const outside = join(TMP_HOME, 'outside.ase');
  writeFileSync(outside, 'o');
  const c2 = Object.assign({}, cfg, { allowOutside: true });
  const plan = backupPlan(c2, outside);
  assert.ok(plan.dir.includes(join('_backup', '_outside')), plan.dir);
});
check('备份失败会抛错（调用方据此中止写入）', () => {
  assert.throws(() => backupFile(cfg, artDir), /EISDIR|EPERM|EBADF|EACCES|ERR/);
});

rmSync(TMP_HOME, { recursive: true, force: true });
console.log('\n==== config: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
