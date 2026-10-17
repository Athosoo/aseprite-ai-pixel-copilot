// 工具注册表 —— 模型能看见、能调用的能力全部来自 registry，这个文件只剩三件事：
// 聚合内置包、把注册项翻成 OpenAI function 描述、派发。
// 判据（arch §1）：新增一项能力要不要改这里？不要，才算分层对了。

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { perfectPixel } from './perfectpixel.mjs';
import { isAsciiName } from './styles.mjs';
import { looksLikeCapabilityGap } from './gaps.mjs';
import { createJournal } from './journal.mjs';
import { createRegistry } from './registry.mjs';
import { createEvolution } from './evolution.mjs';

import canvasPack from '../packs/builtin-canvas/bridge/tools.mjs';
import stylePack from '../packs/builtin-style/bridge/tools.mjs';
import assistPack from '../packs/builtin-assist/bridge/tools.mjs';
import workspacePack from '../packs/builtin-workspace/bridge/tools.mjs';
import drawPack from '../packs/builtin-draw/bridge/tools.mjs';
import pixelPack from '../packs/builtin-pixel/bridge/tools.mjs';
import versionsPack from '../packs/builtin-versions/bridge/tools.mjs';
import memoryPack from '../packs/builtin-memory/bridge/tools.mjs';
import evolutionPack from '../packs/builtin-evolution/bridge/tools.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PACKS_ROOT = join(HERE, '..', 'packs');

export const PACK_DIRS = {
  root: PACKS_ROOT,
  user: join(PACKS_ROOT, 'user'),
  staging: join(PACKS_ROOT, '.staging'),
  snapshots: join(PACKS_ROOT, '.snapshots'),
  journal: join(PACKS_ROOT, '.journal.jsonl'),
};

// RGBA 里有多少种不同的颜色（忽略全透明像素）。
// 给 perfect_pixel 当诊断数据：像素画通常几十色以内，照片则成千上万。
function countDistinctColors(rgba, cap = 4096) {
  const seen = new Set();
  for (let i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] === 0) continue;
    const key = (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
    seen.add(key);
    if (seen.size > cap) return cap + 1;   // 够多了，不用数完
  }
  return seen.size;
}

// 内置包清单：这里的顺序就是发给模型的工具顺序，和 v0.5.x 的 TOOLS 逐项一致，别随手重排。
// 显式写 id 而不是扫目录，是为了让启动顺序不依赖文件系统的枚举顺序。
const BUILTIN_PACKS = [
  ['builtin-canvas', canvasPack],
  ['builtin-style', stylePack],
  ['builtin-assist', assistPack],
  ['builtin-workspace', workspacePack],
  ['builtin-draw', drawPack],
  ['builtin-pixel', pixelPack],
  ['builtin-versions', versionsPack],
  ['builtin-memory', memoryPack],
  ['builtin-evolution', evolutionPack],
];

export const journal = createJournal({ file: PACK_DIRS.journal });
export const registry = createRegistry({ journal: journal.log });

for (const [id, pack] of BUILTIN_PACKS) {
  for (const spec of pack.tools || []) registry.define({ ...spec, pack: id });
}

// 自扩展闭环的操作手柄：一个实例，注册表 / 账本 / 快照目录都和内核共用
export const evolution = createEvolution({
  registry,
  journal: journal.log,
  packsDir: PACK_DIRS.user,
  stagingDir: PACK_DIRS.staging,
  snapDir: PACK_DIRS.snapshots,
});

function toOpenAI(spec) {
  return { type: 'function', function: { name: spec.name, description: spec.description, parameters: spec.inputSchema } };
}

// TOOLS = 内置包的聚合结果，形状与字段和 v0.5.x 完全一致 ——
// 旧测试（tools_test 的注册段、selftest 的能力交叉核对）就钉在这一层。
// 自扩展手柄不在其中：它们走 MODEL_TOOLS，不算"内置能力"。
const LEGACY_PACKS = new Set(BUILTIN_PACKS.map((p) => p[0]).filter((id) => id !== 'builtin-evolution'));
export const TOOLS = registry.list().filter((s) => LEGACY_PACKS.has(s.pack) && s.expose !== false).map(toOpenAI);

// 真正发给模型的清单：内置 + 自扩展手柄（arch §5.5 只增不减）。
// expose:false 的条目（如 gaps_info）只给内核用，绝不进 prompt —— 那是 D5 保持快速的一部分。
export const MODEL_TOOLS = registry.list().filter((s) => s.expose !== false).map(toOpenAI);

// 明确做不到的事（P14）。这份清单必须诚实 —— 用户就是要求"做不到的时候要诚实"，
// 所以宁可写得保守，也不要吹。
const CANNOT = [
  'No network access: you cannot search the web, fetch URLs, or call any service other than the configured LLM.',
  'No arbitrary file access: you can only open image documents (through open_document / the workspace) and write inside the workspace. You cannot read or write other files on the machine.',
  'No vector / audio / font generation. Raster pixel art only.',
  'You cannot undo silently. Every edit is snapshotted first, but going back is an explicit rollback.',
  'You cannot paint outside the canvas: pixels that fall outside are skipped and counted.',
  "You cannot see the screen or the user's UI. You only know the canvas state, layer list, colour histogram and file list you are given.",
  "You cannot dock the panel into the Aseprite layout, and you cannot change Aseprite's own script-permission dialogs (those follow Aseprite's language setting).",
  "You cannot run other Aseprite commands or scripts on the user's behalf beyond the tools listed here.",
];

// 自扩展手柄必须单独列出一组：模型得先知道自己能改自己，才会去用 propose_pack。
// 但绝不并进 can.tools —— 那是"内置能力"这条线，长度被旧测试钉在 25（arch §5.1）。
function evolveHandles() {
  const builtinNames = new Set(TOOLS.map((t) => t.function.name));
  return MODEL_TOOLS
    .filter((t) => !builtinNames.has(t.function.name))
    .map((t) => ({
      name: t.function.name,
      description: String(t.function.description || '').split(/(?<=[.。])\s/)[0],
    }));
}

// 能力清单从【真实注册表】生成，不手写 —— 手写的清单会随代码漂移，那就等于骗人。
// 测试里会和 TOOLS 交叉核对（tools_test.mjs 的 P14 段）。
export function buildCapabilities(session, cfg = {}) {
  const toolList = {};
  for (const t of TOOLS) {
    // 描述取第一句，够用且省 token
    const desc = String(t.function.description || '').split(/(?<=[.。])\s/)[0];
    toolList[t.function.name] = desc;
  }
  // 能打开哪些后缀（和 extension/lib/workspace.lua 的 OPENABLE 表保持一致）
  const OPENABLE = ['ase', 'aseprite', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'pcx', 'tga'];
  const wsRoot = cfg.workspace?.root || '';
  const can = {
    edit_ops: session?.info?.ops || [],
    workspace: wsRoot
      ? { enabled: true, root: wsRoot, note: 'Edits go to a copy; the panel backs up the original first. The user types deliver (交付) to finish.' }
      : { enabled: false, note: 'No workspace configured, so edits land on the open document directly. Ask the user to set one in the panel settings if they want backups + copies.' },
    ui_mode: cfg.ui?.mode || 'panel',
    openable_extensions: OPENABLE,
    tools: toolList,
    evolve: evolveHandles(),
    drawing: 'Character-grid drawing (one character per pixel + a char->colour palette), new documents, layers with opacity and blend modes, reusable art styles.',
    images: 'Open an image/aseprite document, run Perfect Pixel grid correction, and (when a workspace is configured) list and open the files in it.',
    memory: 'Remember colours and free-form notes across sessions, and search them back.',
    snapshots: 'Snapshot and roll back the document version stack.',
  };
  return {
    can,
    cannot: CANNOT,
    honesty: 'Only promise what is in "can". If something is in "cannot", say so plainly instead of guessing or pretending. If the user asks for something not listed, say you cannot do it.',
  };
}

// 能力清单从注册表生成，不手写 —— 手写的清单会随代码漂移，那就等于骗人。
// 测试里会和 TOOLS 交叉核对（tools_test.mjs 的 P14 段）。
export function makeDispatcher({ session, bank, memory, styles, cfg, bundlePath, getActiveStyle, setActiveStyle, gaps }) {
  // 包的 run(ctx, input) 只认这个 ctx：包不 import 内核，所有服务靠注入拿到
  // （包激活时会被复制到别处，相对 import 会断；注入天生免疫这点）。
  const ctx = {
    session, bank, memory, styles, cfg, bundlePath, gaps,
    getActiveStyle, setActiveStyle,
    perfectPixel, countDistinctColors, isAsciiName,
    buildCapabilities: () => buildCapabilities(session, cfg),
    registry, evolution, journal,
  };

  // 每个工具的结果都过一道：出现"做不到"类错误就自动记一笔（模型可能忘了调 log_gap）
  const autoLog = (tool, args, result) => {
    if (!gaps || !result || typeof result !== 'object') return result;
    if (result.ok === true) return result;
    const text = result.error || result.hint || '';
    if (!text || !looksLikeCapabilityGap(text)) return result;
    try {
      gaps.add({
        request: session?.lastUserText || ('(tool ' + tool + ' failed)'),
        why: String(text),
        tool,
        model: cfg?.llm?.model || '',
        context: typeof args === 'object' ? JSON.stringify(args).slice(0, 180) : '',
        source: 'auto',
      });
      result.logged = true;      // 让模型知道"已经记下了"，不用再补一次
    } catch { /* 记不下来不影响这次调用 */ }
    return result;
  };

  return async function dispatch(name, args) {
    const spec = registry.get(name);
    // 未注册工具的文案保持 v0.5.x 原样：面板提示与模型行为都依赖它
    if (!spec) return autoLog(name, args, { error: 'unknown tool: ' + name, hint: 'not supported by this build' });

    const t0 = Date.now();
    let ok = true;
    let out;
    try {
      out = await spec.run(ctx, args || {});
      if (out && typeof out === 'object' && out.error) ok = false;
    } catch (e) {
      ok = false;
      throw e;              // 抛错照旧往上走（llm.mjs 会把它变成一条 tool 结果）
    } finally {
      // 成功/失败都要记：pack_health 的失败率靠这一行，否则自动回滚永远不触发
      evolution.record(spec.pack, Date.now() - t0, ok);
    }
    return autoLog(name, args, out);
  };
}
