// 重新打包 Perfect Pixel 核心（vendor/perfectPixel.mjs）。
//
// 只有【改过上游算法、需要重新打包】时才用得上；仓库里已经带了打包好的
// vendor/perfectPixel.mjs，普通使用者不需要跑这个。
//
// 用法（PP_SRC 指向上游 PerfectPixelStudio 的 perfectPixel.ts）：
//   Windows cmd:  set PP_SRC=D:\path\to\PerfectPixelStudio\src\core\perfectPixel.ts
//   bash:         PP_SRC=/d/path/to/PerfectPixelStudio/src/core/perfectPixel.ts npm run build:pp
//
// 故意不在 package.json 里写死路径 —— 那是原作者机器上的位置。

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';

const src = process.env.PP_SRC;
if (!src) {
  console.error('缺少 PP_SRC。请指向上游 PerfectPixelStudio 的 perfectPixel.ts，例如：');
  console.error('  set PP_SRC=D:\\path\\to\\PerfectPixelStudio\\src\\core\\perfectPixel.ts');
  console.error('（若只是使用本项目，不需要重新打包：vendor/perfectPixel.mjs 已经带在仓库里）');
  process.exit(1);
}
if (!existsSync(src)) {
  console.error(`PP_SRC 指向的文件不存在：${src}`);
  process.exit(1);
}

execFileSync('npx', [
  'esbuild', src,
  '--bundle', '--format=esm', '--platform=node', '--target=es2020',
  '--outfile=vendor/perfectPixel.mjs',
], { stdio: 'inherit' });

console.log('已重新打包 -> vendor/perfectPixel.mjs');
