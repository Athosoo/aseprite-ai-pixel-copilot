/** 冒烟测试：不经过 DSH，直接验证 runner + backup 对真 Aseprite 的路径。
 *  需要本机装了 Aseprite；用临时工作区，不碰真配置。 */
import { existsSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { SCRIPTS, applyScript, exportScript, readManifest, runLua } from '../lib/runner.js';
import { backupFile, ensureWorkspace, loadConfig, resolvePath } from '../lib/config.js';
import { computeManifest } from './manifest-lua.mjs';

const TMP_HOME = mkdtempSync(join(tmpdir(), 'ase-smoke-home-'));
process.env.DSH_ASEPRITE_HOME = TMP_HOME;
const cfg = loadConfig();
ensureWorkspace(cfg);

const ASE = join(cfg.workspace, 'smoke.ase').replace(/\\/g, '/');
const ASE2 = join(cfg.workspace, 'smoke2.ase').replace(/\\/g, '/');
const PNG = join(cfg.exportDir, 'smoke.png').replace(/\\/g, '/');

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '   <- ' + extra : '')); }
}

const make = [
  'local spr = Sprite(32,32,ColorMode.RGB)',
  'local img = spr.cels[1].image',
  'for y=0,31 do for x=0,31 do img:putPixel(x,y,Color(200,30,30,255)) end end',
  'spr:saveAs([[' + ASE + ']])',
  'OUT = "made"',
  ''
].join('\n');

console.log('== status ==');
const st = await runLua(cfg, SCRIPTS.status);
check('版本号拿得到', st.ok && /^\d+\.\d+/.test(st.text), st.text);

console.log('== 算子清单（lib/ops.lua 真源）==');
const manifest = readManifest(cfg.luaRoot);
check('10 个算子都在', manifest.length === 10, manifest.length);
check('含 contrast / sharpen', ['contrast', 'sharpen'].every((n) => manifest.some((e) => e.name === n)));
check('每个算子都带参数 schema', manifest.every((e) => e.params.length > 0));
check('contrast 的 amount 默认 1.3', manifest.find((e) => e.name === 'contrast').params.find((p) => p.name === 'amount').default === 1.3);
check('清单没过期（重跑 ops.manifest() 与文件一致）', await (async () => {
  const fresh = await computeManifest(cfg);
  return JSON.stringify(fresh) === JSON.stringify(manifest);
})());

console.log('== 建图 + 导出 PNG ==');
check('建图成功', (await runLua(cfg, make)).ok);
const ex = await runLua(cfg, exportScript({ file: ASE, out: PNG }));
check('导出返回 ok', ex.ok, ex.text);
check('PNG 真的生成了', existsSync(PNG) && statSync(PNG).size > 0);

console.log('== 跑算子（contrast，另存）==');
const ap = await runLua(cfg, applyScript({ file: ASE, out: ASE2, ops: [{ name: 'contrast', amount: 0.5 }] }));
check('算子执行 ok', ap.ok, ap.text);
check('报告了改动像素数', /changed=\d+/.test(ap.text), ap.text);
check('输出文件生成', existsSync(ASE2));

console.log('== 覆盖前备份 ==');
const b = backupFile(cfg, ASE);
check('备份真的生成', b.skipped === false && existsSync(b.path), b.path);
check('备份落在工作区 _backup 下', b.path.startsWith(join(cfg.workspace, '_backup')), b.path);
const ap2 = await runLua(cfg, applyScript({ file: ASE, out: ASE, ops: [{ name: 'contrast', amount: 1.5 }] }));
check('原地覆盖也成功', ap2.ok, ap2.text);
check('原始内容还在备份里', existsSync(b.path) && statSync(b.path).size > 0);
const keep = readdirSync(join(cfg.workspace, '_backup')).filter((f) => f.endsWith('_smoke.ase'));
check('按源文件裁剪（不会无限增长）', keep.length <= 10, keep.length);

console.log('== 越界拒绝 ==');
const bad = resolvePath(cfg, 'C:/Windows/system32/evil.ase');
check('工作区外路径被拒绝', bad.ok === false && /outside the workspace/.test(bad.error), bad.error);
const allow = resolvePath(Object.assign({}, cfg, { allowOutside: true }), 'C:/Windows/system32/evil.ase');
check('allowOutside=true 才放行', allow.ok === true && allow.outside === true);

rmSync(TMP_HOME, { recursive: true, force: true });
console.log('\n==== smoke: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
