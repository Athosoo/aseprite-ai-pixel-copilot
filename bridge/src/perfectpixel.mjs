// Perfect Pixel Studio 核心算法接入
//
// 核心是零 DOM 依赖的纯 TypeScript（源码 src/core/perfectPixel.ts），
// 由 `npm run build:pp` 用 esbuild 打成 vendor/perfectPixel.mjs 后在这里加载。
// 这样原仓库完全不被改动（不生成它的 node_modules / dist-core）。

import { existsSync } from 'node:fs';

let mod = null;
let loadError = null;

export async function loadCore(bundlePath) {
  if (mod || loadError) return mod;
  if (!existsSync(bundlePath)) {
    loadError = new Error(
      `找不到 Perfect Pixel 核心包：${bundlePath}\n` +
        `请先在 bridge 目录执行： npm install && npm run build:pp`,
    );
    throw loadError;
  }
  mod = await import(new URL('file://' + bundlePath.replace(/\\/g, '/')).href);
  return mod;
}

/**
 * @param {Uint8Array} rgba  输入 RGBA（行优先）
 * @returns {Promise<{detected:boolean, message:string, outWidth:number, outHeight:number, data:Uint8ClampedArray, gridW:number|null, gridH:number|null, refinedW:number, refinedH:number}>}
 */
export async function perfectPixel(bundlePath, rgba, width, height, options = {}) {
  const core = await loadCore(bundlePath);
  const res = core.getPerfectPixel(
    { data: new Uint8ClampedArray(rgba), width, height },
    {
      sampleMethod: options.sampleMethod || 'center',
      gridSize: options.gridSize || null,
      minSize: options.minSize,
      peakWidth: options.peakWidth,
      refineIntensity: options.refineIntensity,
      fixSquare: options.fixSquare,
    },
  );
  return res;
}
