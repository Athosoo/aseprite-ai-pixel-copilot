// 风格库：把"一套作画约束"打包成可切换的模板。
//
// 一个风格 = 调色板 + 推荐尺寸 + 图层结构 + 作画规矩。切换风格时**只把当前那一个**
// 渲染成提示文本注入（约 200 token），不是把所有风格都塞进去 —— 这是省 token 的关键。
//
// 存放：
//   bridge/styles/*.json          随仓库分发的内置风格
//   data/styles/*.json            用户自己存的（style_save 写这里）
// 用户目录的同名风格覆盖内置。

import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const MAX_RULES = 12;
const MAX_TEXT = 300;

// 内置风格：不依赖外部文件，clone 下来就能用。
const BUILTIN = {
  'pixel-icon': {
    name: 'pixel-icon',
    label: '像素图标',
    size: [16, 16],
    palette: ['#1B1B1B', '#2E86DE', '#7EE2A8', '#F5F5F5', '#B03A3A', '#E8C170'],
    layers: ['主体', '高光', '轮廓'],
    rules: [
      '轮廓固定 1px，用调色板里最深的颜色',
      '光源在左上：高光偏左上，暗部在右下',
      '一个图标最多用 4~5 个颜色',
      '不要抗锯齿，边缘保持硬像素',
      '先铺大色块，再加高光和暗部',
    ],
    notes: '适合物品/道具/技能图标。主体尽量占满画布，四周留 1px 以内。',
  },
  'stardew': {
    name: 'stardew',
    label: '星露谷风',
    size: [16, 32],
    palette: ['#3A2412', '#8B5A2B', '#C98A4B', '#E8C170', '#5A8F3D', '#8FBF5A', '#2E4A7D', '#6B9BD1'],
    layers: ['阴影', '主体', '细节', '高光'],
    rules: [
      '暖色调为主，棕色/土黄/草绿占多数',
      '轮廓用深棕而不是纯黑',
      '阴影是柔和的半透明色块，不描边',
      '高光用同色系更亮的一档，不用白色',
      '角色比例偏矮胖（头大身短）',
    ],
    notes: '农场/生活类像素画，适合角色、作物、建筑。',
  },
  'flat-minimal': {
    name: 'flat-minimal',
    label: '极简扁平',
    size: [32, 32],
    palette: ['#2C3E50', '#3498DB', '#1ABC9C', '#ECF0F1', '#E74C3C', '#F39C12'],
    layers: ['主体', '强调'],
    rules: [
      '不要轮廓线，靠色块区分形状',
      '形状尽量几何化（圆/方/三角）',
      '最多 3 个颜色',
      '留白要够，主体不要顶到边',
    ],
    notes: '现代扁平风，适合 UI 图标、示意图形。',
  },
};

export class Styles {
  constructor({ builtinDir, userDir }) {
    this.builtinDir = builtinDir;
    this.userDir = userDir;
    this.userStyles = {};
    mkdirSync(userDir, { recursive: true });
    this.reload();
  }

  reload() {
    this.userStyles = {};
    try {
      for (const f of readdirSync(this.userDir)) {
        if (!f.toLowerCase().endsWith('.json')) continue;
        try {
          const spec = JSON.parse(readFileSync(join(this.userDir, f), 'utf8'));
          const name = String(spec.name || f.replace(/\.json$/i, ''));
          this.userStyles[name] = { ...spec, name, source: 'user' };
        } catch { /* 坏文件跳过，不要让一个坏 json 卡住整个库 */ }
      }
    } catch { /* 目录不存在等，忽略 */ }

    // 仓库里的内置 json 也可以覆盖/补充代码内置的那几个
    this.fileStyles = {};
    if (existsSync(this.builtinDir)) {
      try {
        for (const f of readdirSync(this.builtinDir)) {
          if (!f.toLowerCase().endsWith('.json')) continue;
          try {
            const spec = JSON.parse(readFileSync(join(this.builtinDir, f), 'utf8'));
            const name = String(spec.name || f.replace(/\.json$/i, ''));
            this.fileStyles[name] = { ...spec, name, source: 'file' };
          } catch { /* 同上 */ }
        }
      } catch { /* 忽略 */ }
    }
  }

  all() {
    const merged = {};
    for (const [k, v] of Object.entries(BUILTIN)) merged[k] = { ...v, source: 'builtin' };
    Object.assign(merged, this.fileStyles, this.userStyles);   // 用户 > 文件 > 代码内置
    return merged;
  }

  names() {
    return Object.keys(this.all()).sort();
  }

  get(name) {
    if (!name) return null;
    return this.all()[String(name)] || null;
  }

  save(name, spec = {}) {
    const key = String(name || '').trim();
    if (!key) return { error: 'style needs a name' };
    if (!/^[\w\u4e00-\u9fa5-]+$/.test(key)) {
      return { error: 'name may only contain letters, digits, hyphen, underscore or CJK' };
    }

    const clean = { name: key };
    if (spec.label) clean.label = String(spec.label).slice(0, 60);
    if (Array.isArray(spec.size) && spec.size.length === 2) {
      clean.size = spec.size.map((n) => Math.max(1, Math.floor(Number(n) || 0)));
    }
    if (Array.isArray(spec.palette)) {
      clean.palette = spec.palette
        .map((c) => String(c).trim())
        .filter((c) => /^#[0-9a-fA-F]{6}$/.test(c))
        .slice(0, 32);
    }
    if (Array.isArray(spec.layers)) {
      clean.layers = spec.layers.map((l) => String(l).slice(0, 40)).slice(0, 12);
    }
    if (Array.isArray(spec.rules)) {
      clean.rules = spec.rules.map((r) => String(r).slice(0, MAX_TEXT)).slice(0, MAX_RULES);
    }
    if (spec.notes) clean.notes = String(spec.notes).slice(0, MAX_TEXT);

    const file = join(this.userDir, `${key}.json`);
    writeFileSync(file, JSON.stringify(clean, null, 2), 'utf8');
    this.reload();
    return { ok: true, name: key, file };
  }

  // 渲染成注入用的一小段文本。**只渲染当前这一个风格** —— 别把整库塞进去。
  describe(name) {
    const s = this.get(name);
    if (!s) return null;
    const L = [];
    L.push(`Style: ${s.label || s.name}`);
    if (s.size) L.push(`Canvas size: ${s.size[0]}x${s.size[1]}`);
    if (s.palette?.length) L.push(`Palette (use these): ${s.palette.join(' ')}`);
    if (s.layers?.length) L.push(`Layers, bottom to top: ${s.layers.join(' / ')}`);
    if (s.rules?.length) {
      L.push('Rules:');
      for (const r of s.rules) L.push(`- ${r}`);
    }
    if (s.notes) L.push(`Notes: ${s.notes}`);
    return L.join('\n');
  }
}

export { BUILTIN };
