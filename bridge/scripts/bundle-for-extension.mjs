// 把桥 bundle 成单文件塞进扩展包（tools/pack-extension.ps1 会调它）。
//
// 用 esbuild 的 Node API 而不是 spawn npx：
//   * Windows 上 npx 实际是 npx.cmd，execFileSync('npx', ...) 直接找不到；
//   * esbuild 的 --banner:js 值里带引号和分号，走 shell 会被引号规则折腾。
// 直接调 API 两个问题都没有。
//
// 产出（都在 extension/bridge/ 下，属于构建产物、已 gitignore）：
//   dist/bridge.mjs          自包含的桥（ws 都打进去了），只需系统有 node
//   vendor/perfectPixel.mjs  Perfect Pixel 核心 —— 运行时动态 import，打不进 bundle
//   config.example.json      首次启动时桥会据此生成 config.json

import { copyFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as esbuild from 'esbuild';

const HERE = dirname(fileURLToPath(import.meta.url));
const BRIDGE = join(HERE, '..');
const ROOT = join(BRIDGE, '..');
const STAGE = join(ROOT, 'extension', 'bridge');

mkdirSync(join(STAGE, 'dist'), { recursive: true });
mkdirSync(join(STAGE, 'vendor'), { recursive: true });

await esbuild.build({
  entryPoints: [join(BRIDGE, 'src', 'server.mjs')],
  outfile: join(STAGE, 'dist', 'bridge.mjs'),
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node18',
  // ws 的可选 native 加速模块，装不到也能跑
  external: ['bufferutil', 'utf-8-validate'],
  // ws 是 CJS，bundle 成 ESM 后它内部的 require() 会报
  // "Dynamic require of events is not supported"，得注入 createRequire
  banner: {
    js: "import{createRequire as __cr}from'module';const require=__cr(import.meta.url);",
  },
});

copyFileSync(join(BRIDGE, 'vendor', 'perfectPixel.mjs'), join(STAGE, 'vendor', 'perfectPixel.mjs'));
copyFileSync(join(BRIDGE, 'config.example.json'), join(STAGE, 'config.example.json'));

// 千万别把个人配置（含 API Key）、色值库、日志打进发布包
for (const f of ['config.json', 'bridge.log']) rmSync(join(STAGE, f), { force: true });
rmSync(join(STAGE, 'data'), { recursive: true, force: true });

console.log('[bundle] 已生成 extension/bridge/（dist/bridge.mjs + vendor + config.example.json）');
