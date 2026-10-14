// ../../PerfectPixelStudio/源码/src/core/fft.ts
function isPow2(n) {
  return n > 0 && (n & n - 1) === 0;
}
function fftPow2(re, im, inverse) {
  const n = re.length;
  if (n <= 1) return;
  let j = 0;
  for (let i = 1; i < n; i++) {
    let bit = n >> 1;
    for (; (j & bit) !== 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      const tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      const ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (inverse ? 2 : -2) * Math.PI / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    const half = len >> 1;
    for (let i = 0; i < n; i += len) {
      let cwr = 1;
      let cwi = 0;
      for (let k = 0; k < half; k++) {
        const a = i + k;
        const b = a + half;
        const yr = re[b] * cwr - im[b] * cwi;
        const yi = re[b] * cwi + im[b] * cwr;
        re[b] = re[a] - yr;
        im[b] = im[a] - yi;
        re[a] += yr;
        im[a] += yi;
        const nwr = cwr * wr - cwi * wi;
        cwi = cwr * wi + cwi * wr;
        cwr = nwr;
      }
    }
  }
  if (inverse) {
    const inv = 1 / n;
    for (let i = 0; i < n; i++) {
      re[i] *= inv;
      im[i] *= inv;
    }
  }
}
var bluesteinCache = /* @__PURE__ */ new Map();
function getBluesteinPlan(n) {
  const cached = bluesteinCache.get(n);
  if (cached) return cached;
  let m = 1;
  while (m < 2 * n - 1) m <<= 1;
  const chirpRe = new Float64Array(n);
  const chirpIm = new Float64Array(n);
  for (let k = 0; k < n; k++) {
    const ang = Math.PI * (k * k % (2 * n)) / n;
    chirpRe[k] = Math.cos(ang);
    chirpIm[k] = -Math.sin(ang);
  }
  const bRe = new Float64Array(m);
  const bIm = new Float64Array(m);
  for (let k = 0; k < n; k++) {
    const ang = Math.PI * (k * k % (2 * n)) / n;
    const cr = Math.cos(ang);
    const ci = Math.sin(ang);
    bRe[k] = cr;
    bIm[k] = ci;
    if (k > 0) {
      bRe[m - k] = cr;
      bIm[m - k] = ci;
    }
  }
  fftPow2(bRe, bIm, false);
  const plan = { M: m, chirpRe, chirpIm, bRe, bIm };
  bluesteinCache.set(n, plan);
  return plan;
}
function fftArbitrary(re, im, n) {
  if (n <= 1) return;
  if (isPow2(n)) {
    fftPow2(re, im, false);
    return;
  }
  const { M, chirpRe, chirpIm, bRe, bIm } = getBluesteinPlan(n);
  const aRe = new Float64Array(M);
  const aIm = new Float64Array(M);
  for (let k = 0; k < n; k++) {
    const xr = re[k];
    const xi = im[k];
    aRe[k] = xr * chirpRe[k] - xi * chirpIm[k];
    aIm[k] = xr * chirpIm[k] + xi * chirpRe[k];
  }
  fftPow2(aRe, aIm, false);
  for (let i = 0; i < M; i++) {
    const xr = aRe[i] * bRe[i] - aIm[i] * bIm[i];
    const xi = aRe[i] * bIm[i] + aIm[i] * bRe[i];
    aRe[i] = xr;
    aIm[i] = xi;
  }
  fftPow2(aRe, aIm, true);
  for (let k = 0; k < n; k++) {
    const cr = aRe[k];
    const ci = aIm[k];
    re[k] = cr * chirpRe[k] - ci * chirpIm[k];
    im[k] = cr * chirpIm[k] + ci * chirpRe[k];
  }
}
function fft2InPlace(re, im, height, width) {
  const rowRe = new Float64Array(width);
  const rowIm = new Float64Array(width);
  for (let y = 0; y < height; y++) {
    const off = y * width;
    for (let x = 0; x < width; x++) {
      rowRe[x] = re[off + x];
      rowIm[x] = im[off + x];
    }
    fftArbitrary(rowRe, rowIm, width);
    for (let x = 0; x < width; x++) {
      re[off + x] = rowRe[x];
      im[off + x] = rowIm[x];
    }
  }
  const colRe = new Float64Array(height);
  const colIm = new Float64Array(height);
  for (let x = 0; x < width; x++) {
    for (let y = 0; y < height; y++) {
      colRe[y] = re[y * width + x];
      colIm[y] = im[y * width + x];
    }
    fftArbitrary(colRe, colIm, height);
    for (let y = 0; y < height; y++) {
      re[y * width + x] = colRe[y];
      im[y * width + x] = colIm[y];
    }
  }
}
function computeFftMagnitude(gray, height, width) {
  const n = height * width;
  const re = new Float64Array(n);
  const im = new Float64Array(n);
  re.set(gray.subarray(0, n));
  fft2InPlace(re, im, height, width);
  const mag = new Float64Array(n);
  const cy = height >> 1;
  const cx = width >> 1;
  let mn = Infinity;
  let mx = -Infinity;
  for (let y = 0; y < height; y++) {
    const sy = (y + cy) % height;
    const src = sy * width;
    const dst = y * width;
    for (let x = 0; x < width; x++) {
      const sx = (x + cx) % width;
      const idx = src + sx;
      const r = re[idx];
      const i = im[idx];
      const v = 1 - Math.log1p(Math.sqrt(r * r + i * i));
      mag[dst + x] = v;
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
  }
  if (mx - mn < 1e-8) {
    return new Float64Array(n);
  }
  const inv = 1 / (mx - mn);
  for (let i = 0; i < n; i++) {
    mag[i] = (mag[i] - mn) * inv;
  }
  return mag;
}

// ../../PerfectPixelStudio/源码/src/core/imageOps.ts
var R2Y = 4899;
var G2Y = 9617;
var B2Y = 1868;
var YUV_HALF = 1 << 13;
function clamp(v, lo, hi) {
  return v < lo ? lo : v > hi ? hi : v;
}
function rintHalfEven(x) {
  if (!Number.isFinite(x)) return 0;
  const t = Math.floor(x);
  const diff = x - t;
  if (diff < 0.5) return t;
  if (diff > 0.5) return t + 1;
  return t % 2 === 0 ? t : t + 1;
}
function toGrayBgr2Gray(rgba, width, height) {
  const n = width * height;
  const gray = new Float64Array(n);
  for (let i = 0, p = 0; i < n; i++, p += 4) {
    const r = rgba[p];
    const g = rgba[p + 1];
    const b = rgba[p + 2];
    gray[i] = B2Y * r + G2Y * g + R2Y * b + YUV_HALF >> 14;
  }
  return gray;
}
function reflect101(i, n) {
  if (n === 1) return 0;
  if (i < 0) return -i;
  if (i >= n) return 2 * n - 2 - i;
  return i;
}
function sobel3x3(gray, width, height, dx, dy) {
  const kx = dx === 1 ? [-1, 0, 1, -2, 0, 2, -1, 0, 1] : [-1, -2, -1, 0, 0, 0, 1, 2, 1];
  const out = new Float64Array(width * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      let s = 0;
      for (let ky = -1; ky <= 1; ky++) {
        const yy = reflect101(y + ky, height);
        const krow = (ky + 1) * 3;
        for (let kxi = -1; kxi <= 1; kxi++) {
          const xx = reflect101(x + kxi, width);
          s += kx[krow + (kxi + 1)] * gray[yy * width + xx];
        }
      }
      out[y * width + x] = s;
    }
  }
  return out;
}
function sumAbsColumns(grad, width, height) {
  const res = new Float64Array(width);
  for (let x = 0; x < width; x++) {
    let s = 0;
    for (let y = 0; y < height; y++) {
      const v = grad[y * width + x];
      s += v < 0 ? -v : v;
    }
    res[x] = s;
  }
  return res;
}
function sumAbsRows(grad, width, height) {
  const res = new Float64Array(height);
  for (let y = 0; y < height; y++) {
    let s = 0;
    const off = y * width;
    for (let x = 0; x < width; x++) {
      const v = grad[off + x];
      s += v < 0 ? -v : v;
    }
    res[y] = s;
  }
  return res;
}
function normalizeMinMax(v) {
  const n = v.length;
  let mn = Infinity;
  let mx = -Infinity;
  for (let i = 0; i < n; i++) {
    const x = v[i];
    if (x < mn) mn = x;
    if (x > mx) mx = x;
  }
  const out = new Float64Array(n);
  const diff = mx - mn;
  if (diff === 0) {
    return out;
  }
  for (let i = 0; i < n; i++) {
    out[i] = (v[i] - mn) / diff;
  }
  return out;
}
function smooth1d(v, k = 17) {
  let kk = Math.trunc(k);
  if (kk < 3) return v;
  if (kk % 2 === 0) kk += 1;
  const sigma = kk / 6;
  const ker = new Float64Array(kk);
  let sum = 0;
  const half = Math.floor(kk / 2);
  for (let i = 0; i < kk; i++) {
    const x = i - half;
    const val = Math.exp(-(x * x) / (2 * sigma * sigma));
    ker[i] = val;
    sum += val;
  }
  const norm = sum + 1e-8;
  for (let i = 0; i < kk; i++) ker[i] /= norm;
  const n = v.length;
  const out = new Float64Array(n);
  const pad = kk - 1 >> 1;
  for (let i = 0; i < n; i++) {
    let acc = 0;
    for (let j = 0; j < kk; j++) {
      const ai = i + pad - j;
      if (ai >= 0 && ai < n) acc += v[ai] * ker[j];
    }
    out[i] = acc;
  }
  return out;
}
function medianInPlace(values, count) {
  if (count === 0) return 0;
  const view = values.subarray(0, count);
  view.sort();
  const mid = count >> 1;
  if (count % 2 === 1) return view[mid];
  return (view[mid - 1] + view[mid]) * 0.5;
}
function mulberry32(seed) {
  let a = seed >>> 0;
  return function next() {
    a |= 0;
    a = a + 1831565813 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function toInt32(v) {
  return Math.trunc(v);
}
function sampleCenter(rgba, imgW, imgH, xs, ys) {
  const nx = xs.length - 1;
  const ny = ys.length - 1;
  const outW = Math.max(nx, 0);
  const outH = Math.max(ny, 0);
  const out = new Uint8ClampedArray(outW * outH * 4);
  const cx = new Int32Array(outW);
  for (let i = 0; i < outW; i++) {
    cx[i] = toInt32(clamp((xs[i] + xs[i + 1]) * 0.5, 0, imgW - 1));
  }
  const cy = new Int32Array(outH);
  for (let j = 0; j < outH; j++) {
    cy[j] = toInt32(clamp((ys[j] + ys[j + 1]) * 0.5, 0, imgH - 1));
  }
  for (let j = 0; j < outH; j++) {
    const srcRow = cy[j] * imgW;
    const dstRow = j * outW;
    for (let i = 0; i < outW; i++) {
      const s = (srcRow + cx[i]) * 4;
      const d = (dstRow + i) * 4;
      out[d] = rgba[s];
      out[d + 1] = rgba[s + 1];
      out[d + 2] = rgba[s + 2];
      out[d + 3] = 255;
    }
  }
  return { data: out, width: outW, height: outH };
}
function sampleMedian(rgba, imgW, imgH, xs, ys) {
  const x = xs.map(toInt32);
  const y = ys.map(toInt32);
  const nx = Math.max(x.length - 1, 0);
  const ny = Math.max(y.length - 1, 0);
  const out = new Uint8ClampedArray(nx * ny * 4);
  const maxCell = Math.max(1, imgW * imgH);
  const buffer = new Float64Array(maxCell);
  for (let j = 0; j < ny; j++) {
    let y0 = clamp(y[j], 0, imgH);
    let y1 = clamp(y[j + 1], 0, imgH);
    if (y1 <= y0) y1 = Math.min(y0 + 1, imgH);
    for (let i = 0; i < nx; i++) {
      let x0 = clamp(x[i], 0, imgW);
      let x1 = clamp(x[i + 1], 0, imgW);
      if (x1 <= x0) x1 = Math.min(x0 + 1, imgW);
      const d = (j * nx + i) * 4;
      const cellW = x1 - x0;
      const cellH = y1 - y0;
      const count = cellW * cellH;
      if (count === 0) {
        out[d] = 0;
        out[d + 1] = 0;
        out[d + 2] = 0;
        out[d + 3] = 255;
        continue;
      }
      for (let c = 0; c < 3; c++) {
        let t = 0;
        for (let yy = y0; yy < y1; yy++) {
          const off = yy * imgW;
          for (let xx = x0; xx < x1; xx++) {
            buffer[t++] = rgba[(off + xx) * 4 + c];
          }
        }
        const m = medianInPlace(buffer, count);
        out[d + c] = clamp(rintHalfEven(m), 0, 255);
      }
      out[d + 3] = 255;
    }
  }
  return { data: out, width: nx, height: ny };
}
function kmeans2(points, count, channels) {
  const centers = new Float64Array(2 * channels);
  let c0 = 0;
  let bestDist = -1;
  let c1 = 0;
  for (let i = 0; i < count; i++) {
    let d = 0;
    for (let k = 0; k < channels; k++) {
      const diff = points[i * channels + k] - points[k];
      d += diff * diff;
    }
    if (d > bestDist) {
      bestDist = d;
      c1 = i;
    }
  }
  if (c1 === c0) c1 = count > 1 ? 1 : 0;
  for (let k = 0; k < channels; k++) {
    centers[k] = points[c0 * channels + k];
    centers[channels + k] = points[c1 * channels + k];
  }
  const labels = new Int32Array(count);
  const sum = new Float64Array(2 * channels);
  const cnt = [0, 0];
  const iters = 6;
  const eps = 1;
  for (let it = 0; it < iters; it++) {
    let changed = false;
    for (let i = 0; i < count; i++) {
      let d0 = 0;
      let d1 = 0;
      const base = i * channels;
      for (let k = 0; k < channels; k++) {
        const v = points[base + k];
        const a = v - centers[k];
        const b = v - centers[channels + k];
        d0 += a * a;
        d1 += b * b;
      }
      const label = d1 < d0 ? 1 : 0;
      if (label !== labels[i]) {
        labels[i] = label;
        changed = true;
      }
    }
    sum.fill(0);
    cnt[0] = 0;
    cnt[1] = 0;
    for (let i = 0; i < count; i++) {
      const l = labels[i];
      cnt[l]++;
      const base = i * channels;
      for (let k = 0; k < channels; k++) sum[l * channels + k] += points[base + k];
    }
    let shift = 0;
    for (let l = 0; l < 2; l++) {
      if (cnt[l] === 0) continue;
      for (let k = 0; k < channels; k++) {
        const nc = sum[l * channels + k] / cnt[l];
        const diff = nc - centers[l * channels + k];
        if (Math.abs(diff) > shift) shift = Math.abs(diff);
        centers[l * channels + k] = nc;
      }
    }
    if (!changed || shift <= eps) break;
  }
  let count1 = 0;
  for (let i = 0; i < count; i++) if (labels[i] === 1) count1++;
  const count0 = count - count1;
  const chosen = count1 >= count0 ? 1 : 0;
  const result = new Float64Array(channels);
  for (let k = 0; k < channels; k++) result[k] = centers[chosen * channels + k];
  return { center: result };
}
function sampleMajority(rgba, imgW, imgH, xs, ys, maxSamples = 128, seed = 42) {
  const x = xs.map(toInt32);
  const y = ys.map(toInt32);
  const nx = Math.max(x.length - 1, 0);
  const ny = Math.max(y.length - 1, 0);
  const out = new Uint8ClampedArray(nx * ny * 4);
  const rand = mulberry32(seed);
  const maxCell = Math.max(1, imgW * imgH);
  const cellBuf = new Float64Array(maxCell * 3);
  for (let j = 0; j < ny; j++) {
    let y0 = clamp(y[j], 0, imgH);
    let y1 = clamp(y[j + 1], 0, imgH);
    if (y1 <= y0) y1 = Math.min(y0 + 1, imgH);
    for (let i = 0; i < nx; i++) {
      let x0 = clamp(x[i], 0, imgW);
      let x1 = clamp(x[i + 1], 0, imgW);
      if (x1 <= x0) x1 = Math.min(x0 + 1, imgW);
      const d = (j * nx + i) * 4;
      let count = 0;
      for (let yy = y0; yy < y1; yy++) {
        const off = yy * imgW;
        for (let xx = x0; xx < x1; xx++) {
          const s = (off + xx) * 4;
          cellBuf[count * 3] = rgba[s];
          cellBuf[count * 3 + 1] = rgba[s + 1];
          cellBuf[count * 3 + 2] = rgba[s + 2];
          count++;
        }
      }
      if (count === 0) {
        out[d + 3] = 255;
        continue;
      }
      let useCount = count;
      let sample2 = cellBuf;
      if (count > maxSamples) {
        const sub = new Float64Array(maxSamples * 3);
        for (let t = 0; t < maxSamples; t++) {
          const idx = Math.floor(rand() * count);
          sub[t * 3] = cellBuf[idx * 3];
          sub[t * 3 + 1] = cellBuf[idx * 3 + 1];
          sub[t * 3 + 2] = cellBuf[idx * 3 + 2];
        }
        sample2 = sub;
        useCount = maxSamples;
      }
      if (useCount < 2) {
        out[d] = clamp(rintHalfEven(sample2[0]), 0, 255);
        out[d + 1] = clamp(rintHalfEven(sample2[1]), 0, 255);
        out[d + 2] = clamp(rintHalfEven(sample2[2]), 0, 255);
        out[d + 3] = 255;
        continue;
      }
      const { center } = kmeans2(sample2, useCount, 3);
      out[d] = clamp(rintHalfEven(center[0]), 0, 255);
      out[d + 1] = clamp(rintHalfEven(center[1]), 0, 255);
      out[d + 2] = clamp(rintHalfEven(center[2]), 0, 255);
      out[d + 3] = 255;
    }
  }
  return { data: out, width: nx, height: ny };
}

// ../../PerfectPixelStudio/源码/src/core/perfectPixel.ts
function detectPeak(proj, peakWidth = 6, relThr = 0.35, minDist = 6) {
  const n = proj.length;
  const center = Math.floor(n / 2);
  let mx = proj[0];
  for (let i = 1; i < n; i++) if (proj[i] > mx) mx = proj[i];
  if (mx < 1e-6) return null;
  const thr = mx * relThr;
  const candidates = [];
  for (let i = 1; i < n - 1; i++) {
    let isPeak = true;
    for (let j = 1; j < peakWidth; j++) {
      if (i - j < 0 || i + j >= n) continue;
      if (proj[i - j + 1] < proj[i - j] || proj[i + j - 1] < proj[i + j]) {
        isPeak = false;
        break;
      }
    }
    if (isPeak && proj[i] >= thr) {
      let leftClimb = 0;
      for (let k = i; k > 0; k--) {
        if (proj[k] > proj[k - 1]) leftClimb = Math.abs(proj[i] - proj[k - 1]);
        else break;
      }
      let rightFall = 0;
      for (let k = i; k < n - 1; k++) {
        if (proj[k] > proj[k + 1]) rightFall = Math.abs(proj[i] - proj[k + 1]);
        else break;
      }
      candidates.push({ index: i, score: Math.max(leftClimb, rightFall) });
    }
  }
  if (candidates.length === 0) return null;
  const left = candidates.filter((c) => c.index < center - minDist && c.index > center * 0.25);
  const right = candidates.filter((c) => c.index > center + minDist && c.index < center * 1.75);
  const byScoreDesc = (a, b) => b.score - a.score;
  left.sort(byScoreDesc);
  right.sort(byScoreDesc);
  if (left.length === 0 || right.length === 0) return null;
  return Math.abs(right[0].index - left[0].index) / 2;
}
function estimateGridFft(gray, width, height, peakWidth = 6) {
  const mag = computeFftMagnitude(gray, height, width);
  const bandRow = width >> 1;
  const bandCol = height >> 1;
  const colStart = 0;
  const colEnd = 2 * bandRow;
  const rowStart = 0;
  const rowEnd = 2 * bandCol;
  const rowSum = new Float64Array(height);
  for (let y = 0; y < height; y++) {
    let s = 0;
    const off = y * width;
    for (let x = colStart; x < colEnd; x++) s += mag[off + x];
    rowSum[y] = s;
  }
  const colSum = new Float64Array(width);
  for (let x = 0; x < width; x++) {
    let s = 0;
    for (let y = rowStart; y < rowEnd; y++) s += mag[y * width + x];
    colSum[x] = s;
  }
  const rowNorm = smooth1d(normalizeMinMax(rowSum), 17);
  const colNorm = smooth1d(normalizeMinMax(colSum), 17);
  const scaleRow = detectPeak(rowNorm, peakWidth);
  const scaleCol = detectPeak(colNorm, peakWidth);
  if (scaleRow === null || scaleCol === null || scaleCol <= 0) {
    return null;
  }
  const gridW = rintHalfEven(scaleCol);
  const gridH = rintHalfEven(scaleRow);
  return [gridW, gridH];
}
function medianOfIntervals(peaks) {
  const n = peaks.length - 1;
  if (n <= 0) return 0;
  const intervals = [];
  for (let i = 1; i < peaks.length; i++) intervals.push(peaks[i] - peaks[i - 1]);
  intervals.sort((a, b) => a - b);
  const mid = intervals.length >> 1;
  if (intervals.length % 2 === 1) return intervals[mid];
  return (intervals[mid - 1] + intervals[mid]) / 2;
}
function findLocalMaxima(sums, relThr, minInterval = 4) {
  let mx = sums[0];
  for (let i = 1; i < sums.length; i++) if (sums[i] > mx) mx = sums[i];
  const thr = relThr * mx;
  const peaks = [];
  for (let i = 1; i < sums.length - 1; i++) {
    if (sums[i] > sums[i - 1] && sums[i] > sums[i + 1] && sums[i] >= thr) {
      if (peaks.length === 0 || i - peaks[peaks.length - 1] >= minInterval) {
        peaks.push(i);
      }
    }
  }
  return peaks;
}
function estimateGridGradient(gray, width, height, relThr = 0.2) {
  const gradX = sobel3x3(gray, width, height, 1, 0);
  const gradY = sobel3x3(gray, width, height, 0, 1);
  const gradXSum = sumAbsColumns(gradX, width, height);
  const gradYSum = sumAbsRows(gradY, width, height);
  const peakX = findLocalMaxima(gradXSum, relThr);
  const peakY = findLocalMaxima(gradYSum, relThr);
  if (peakX.length < 4 || peakY.length < 4) return null;
  const scaleX = width / medianOfIntervals(peakX);
  const scaleY = height / medianOfIntervals(peakY);
  return [rintHalfEven(scaleX), rintHalfEven(scaleY)];
}
function detectGridScale(rgba, width, height, peakWidth = 6, maxRatio = 1.5, minSize = 4) {
  const gray = toGrayBgr2Gray(rgba, width, height);
  let result = estimateGridFft(gray, width, height, peakWidth);
  if (result === null) {
    result = estimateGridGradient(gray, width, height);
  } else {
    const [gw, gh] = result;
    const pixelSizeX2 = width / gw;
    const pixelSizeY2 = height / gh;
    const maxPixelSize = 20;
    if (Math.min(pixelSizeX2, pixelSizeY2) < minSize || Math.max(pixelSizeX2, pixelSizeY2) > maxPixelSize || pixelSizeX2 / pixelSizeY2 > maxRatio || pixelSizeY2 / pixelSizeX2 > maxRatio) {
      result = estimateGridGradient(gray, width, height);
    }
  }
  if (result === null) return null;
  const pixelSizeX = width / result[0];
  const pixelSizeY = height / result[1];
  let pixelSize;
  if (pixelSizeX / pixelSizeY > maxRatio || pixelSizeY / pixelSizeX > maxRatio) {
    pixelSize = Math.min(pixelSizeX, pixelSizeY);
  } else {
    pixelSize = (pixelSizeX + pixelSizeY) / 2;
  }
  const gridW = rintHalfEven(width / pixelSize);
  const gridH = rintHalfEven(height / pixelSize);
  return [gridW, gridH];
}
function findBestGrid(origin, rangeValMin, rangeValMax, gradMag, thr = 0) {
  let best = rintHalfEven(origin);
  let mx = gradMag[0];
  for (let i = 1; i < gradMag.length; i++) if (gradMag[i] > mx) mx = gradMag[i];
  if (mx < 1e-6) return best;
  const relThr = mx * thr;
  const peaks = [];
  const iMin = -rintHalfEven(rangeValMin);
  const iMax = rintHalfEven(rangeValMax);
  const n = gradMag.length;
  for (let i = iMin; i <= iMax; i++) {
    const candidate = rintHalfEven(origin + i);
    if (candidate <= 0 || candidate >= n - 1) continue;
    if (gradMag[candidate] > gradMag[candidate - 1] && gradMag[candidate] > gradMag[candidate + 1] && gradMag[candidate] >= relThr) {
      peaks.push([gradMag[candidate], candidate]);
    }
  }
  if (peaks.length === 0) return best;
  peaks.sort((a, b) => b[0] - a[0]);
  best = peaks[0][1];
  return best;
}
function computeGridPeaks(rgba, width, height) {
  const gray = toGrayBgr2Gray(rgba, width, height);
  const gradX = sobel3x3(gray, width, height, 1, 0);
  const gradY = sobel3x3(gray, width, height, 0, 1);
  return {
    gx: sumAbsColumns(gradX, width, height),
    gy: sumAbsRows(gradY, width, height)
  };
}
function refineGrids(rgba, width, height, gridX, gridY, refineIntensity = 0.25) {
  const { gx, gy } = computeGridPeaks(rgba, width, height);
  const cellW = width / gridX;
  const cellH = height / gridY;
  const xCoords = [];
  const yCoords = [];
  let x = findBestGrid(width / 2, cellW, cellW, gx);
  while (x < width + cellW / 2) {
    x = findBestGrid(x, cellW * refineIntensity, cellW * refineIntensity, gx);
    xCoords.push(x);
    x += cellW;
  }
  x = findBestGrid(width / 2, cellW, cellW, gx) - cellW;
  while (x > -cellW / 2) {
    x = findBestGrid(x, cellW * refineIntensity, cellW * refineIntensity, gx);
    xCoords.push(x);
    x -= cellW;
  }
  let y = findBestGrid(height / 2, cellH, cellH, gy);
  while (y < height + cellH / 2) {
    y = findBestGrid(y, cellH * refineIntensity, cellH * refineIntensity, gy);
    yCoords.push(y);
    y += cellH;
  }
  y = findBestGrid(height / 2, cellH, cellH, gy) - cellH;
  while (y > -cellH / 2) {
    y = findBestGrid(y, cellH * refineIntensity, cellH * refineIntensity, gy);
    yCoords.push(y);
    y -= cellH;
  }
  xCoords.sort((a, b) => a - b);
  yCoords.sort((a, b) => a - b);
  return { xCoords, yCoords };
}
function fixSquare(scaled, refinedW, refinedH) {
  if (Math.abs(refinedW - refinedH) !== 1) return scaled;
  const w = scaled.width;
  const h = scaled.height;
  const copyRows = (rows, newH) => {
    const data = new Uint8ClampedArray(w * newH * 4);
    for (let j = 0; j < newH; j++) {
      const src = rows[j];
      data.set(scaled.data.subarray(src * w * 4, (src + 1) * w * 4), j * w * 4);
    }
    return { data, width: w, height: newH };
  };
  const copyCols = (cols, newW) => {
    const data = new Uint8ClampedArray(newW * h * 4);
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < newW; i++) {
        const src = cols[i];
        const s = (j * w + src) * 4;
        const d = (j * newW + i) * 4;
        data[d] = scaled.data[s];
        data[d + 1] = scaled.data[s + 1];
        data[d + 2] = scaled.data[s + 2];
        data[d + 3] = scaled.data[s + 3];
      }
    }
    return { data, width: newW, height: h };
  };
  if (refinedW > refinedH) {
    if (refinedW % 2 === 1) {
      return copyCols(
        Array.from({ length: w - 1 }, (_, i) => i),
        w - 1
      );
    }
    return copyRows([0, ...Array.from({ length: h }, (_, i) => i)], h + 1);
  }
  if (refinedH % 2 === 1) {
    return copyRows(
      Array.from({ length: h - 1 }, (_, i) => i),
      h - 1
    );
  }
  return copyCols([0, ...Array.from({ length: w }, (_, i) => i)], w + 1);
}
var METHODS = ["center", "median", "majority"];
function normalizeMethod(m) {
  return m && METHODS.includes(m) ? m : "center";
}
function sample(method, rgba, width, height, xs, ys) {
  switch (method) {
    case "median":
      return sampleMedian(rgba, width, height, xs, ys);
    case "majority":
      return sampleMajority(rgba, width, height, xs, ys);
    case "center":
    default:
      return sampleCenter(rgba, width, height, xs, ys);
  }
}
function detectGrid(image, options = {}) {
  const peakWidth = options.peakWidth ?? 6;
  const minSize = options.minSize ?? 4;
  return detectGridScale(image.data, image.width, image.height, peakWidth, 1.5, minSize);
}
function processWithGrid(image, gridSize, options = {}) {
  const method = normalizeMethod(options.sampleMethod);
  const refineIntensity = options.refineIntensity ?? 0.25;
  const fixSquareEnabled = options.fixSquare ?? true;
  const { width: W, height: H } = image;
  const sizeX = rintHalfEven(gridSize[0]);
  const sizeY = rintHalfEven(gridSize[1]);
  const { xCoords, yCoords } = refineGrids(image.data, W, H, sizeX, sizeY, refineIntensity);
  const refinedW = xCoords.length - 1;
  const refinedH = yCoords.length - 1;
  let scaled = sample(method, image.data, W, H, xCoords, yCoords);
  if (fixSquareEnabled) {
    scaled = fixSquare(scaled, refinedW, refinedH);
  }
  return {
    detected: true,
    message: "\u5904\u7406\u5B8C\u6210",
    inputWidth: W,
    inputHeight: H,
    gridW: sizeX,
    gridH: sizeY,
    refinedW,
    refinedH,
    outWidth: scaled.width,
    outHeight: scaled.height,
    xCoords,
    yCoords,
    data: scaled.data
  };
}
function getPerfectPixel(image, options = {}) {
  const { width: W, height: H } = image;
  let gridSize;
  if (options.gridSize) {
    gridSize = [rintHalfEven(options.gridSize[0]), rintHalfEven(options.gridSize[1])];
  } else {
    gridSize = detectGrid(image, options);
  }
  if (!gridSize || gridSize[0] === null || gridSize[1] === null) {
    return {
      detected: false,
      message: "\u672A\u80FD\u68C0\u6D4B\u5230\u7F51\u683C\uFF1A\u8BE5\u56FE\u7247\u53EF\u80FD\u4E0D\u662F\u50CF\u7D20\u753B\uFF0C\u6216\u7F51\u683C\u4E0D\u89C4\u5219\u3002\u53EF\u5C1D\u8BD5\u624B\u52A8\u6307\u5B9A\u7F51\u683C\u5C3A\u5BF8\u3002",
      inputWidth: W,
      inputHeight: H,
      gridW: null,
      gridH: null,
      refinedW: 0,
      refinedH: 0,
      outWidth: 0,
      outHeight: 0,
      xCoords: [],
      yCoords: [],
      data: new Uint8ClampedArray(0)
    };
  }
  return processWithGrid(image, gridSize, options);
}
export {
  detectGrid,
  detectGridScale,
  detectPeak,
  estimateGridFft,
  estimateGridGradient,
  findBestGrid,
  getPerfectPixel,
  processWithGrid,
  refineGrids
};
