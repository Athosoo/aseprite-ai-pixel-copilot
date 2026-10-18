/** 把插件同步进 desktop profile 的 node_modules（DSH 只从那里加载）。
 *  只做覆盖复制，不做删除 —— 避免触发本机的删除防护。
 *  源 = 本仓库根（脚本在 test/ 下，所以向上一级）。 */
import { cpSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const src = fileURLToPath(new URL('../', import.meta.url));
const dst = join(homedir(), '.dsh', 'profiles', 'desktop', 'node_modules', 'dsh-plugin-aseprite');

const files = [
  'package.json', 'cordis.patch.yml', 'README.md', 'DESIGN.md', 'STATUS.md', 'LICENSE',
  'lib/index.js', 'lib/runner.js', 'lib/config.js', 'lib/opsinfo.js',
  'client/client.js'
];
for (const rel of files) {
  const from = join(src, rel);
  if (!existsSync(from)) { console.log('skip missing ' + rel); continue; }
  cpSync(from, join(dst, rel), { force: true });
  console.log('synced ' + rel);
}

// 领域层 + 清单：lib/ 下的 .lua 与 ops.manifest.json 必须一起过去（require("lib.ops") 靠它们）
const lua = ['lib/ops.lua', 'lib/util.lua', 'lib/ops.manifest.json'];
for (const rel of lua) {
  const from = join(src, rel);
  if (!existsSync(from)) { console.log('skip missing ' + rel); continue; }
  cpSync(from, join(dst, rel), { force: true });
  console.log('synced ' + rel);
}
