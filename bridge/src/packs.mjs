// 能力包装载器：动态 import + cache-busting query 实现热重载。
// 这是 Node 侧唯一容易"假通过"的地方 —— 少写 ?v= 就命中模块缓存，
// 文件改了但实现变了没有，测试会绿、线上不动。所以 URL 里必须带 mtime+size。
import { existsSync, readFileSync, statSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const SUPPORTED_API = 1;

// §4 冻结了 packs/<id>/bridge/tools.mjs，§2 的桥侧图又画成 packs/<id>/tools.mjs。
// 两种都认（先 bridge/），免得因为目录层级差一层就整包不装。
function pickModule(dir, name) {
  for (const rel of [`bridge/${name}`, name]) {
    const p = join(dir, rel);
    if (existsSync(p)) return p;
  }
  return '';
}

function stampOf(file) {
  const st = statSync(file);
  return `${st.mtimeMs.toString(36)}x${st.size.toString(36)}`;
}

function readManifest(dir) {
  const p = join(dir, 'manifest.json');
  if (!existsSync(p)) throw new Error('manifest.json missing');
  let m;
  try { m = JSON.parse(readFileSync(p, 'utf8')); } catch (e) { throw new Error(`manifest.json is not valid JSON: ${e.message}`); }
  if (!m || typeof m !== 'object') throw new Error('manifest.json must be an object');
  if (!m.id || typeof m.id !== 'string') throw new Error('manifest.id is required');
  if (m.api !== SUPPORTED_API) throw new Error(`manifest.api must be ${SUPPORTED_API}, got ${JSON.stringify(m.api)}`);
  if (!Array.isArray(m.ops)) m.ops = [];
  return m;
}

function normalizeTools(mod) {
  const raw = mod?.default ?? mod;
  const list = Array.isArray(raw) ? raw : (Array.isArray(raw?.tools) ? raw.tools : null);
  if (!list) throw new Error('tools module must export default { tools: [...] } or an array');
  return list;
}

async function loadOne(dir, { registry, journal }) {
  const manifest = readManifest(dir);
  const specFile = pickModule(dir, 'tools.mjs');
  let tools = [];
  let stamp = '';

  if (specFile) {
    stamp = stampOf(specFile);
    const url = `${pathToFileURL(specFile).href}?v=${stamp}`;
    let mod;
    try {
      mod = await import(url);
    } catch (e) {
      throw new Error(`tools.mjs failed to import: ${e?.message || e}`);
    }
    tools = normalizeTools(mod);
    for (const spec of tools) {
      registry.define({
        ...spec,
        pack: manifest.id,
        // 只给 since：evolved 由 registry 按"是否覆盖过"自己判，包不该自封
        meta: { since: stamp },
      });
    }
  }

  // 重载后消失的工具必须从注册表里摘掉，否则"模型删掉一个能力"会留下幽灵条目
  const keep = new Set(tools.map((t) => t.name));
  for (const s of registry.list()) {
    if (s.pack === manifest.id && !keep.has(s.name)) registry.remove(s.name);
  }

  journal?.({ kind: 'pack.load', id: manifest.id, dir, tools: [...keep], stamp });
  return { id: manifest.id, name: manifest.name || manifest.id, version: manifest.version || '', dir, tools: [...keep], stamp };
}

export async function loadPacks({ dirs = [], registry, journal } = {}) {
  if (!registry) throw new TypeError('loadPacks: registry is required');
  const loaded = [];
  const errors = [];

  for (const dir of dirs) {
    if (!dir || !existsSync(dir)) continue;
    const entries = readdirSync(dir, { withFileTypes: true })
      .filter((d) => d.isDirectory() && !d.name.startsWith('.'))
      .map((d) => join(dir, d.name))
      .sort();

    for (const packDir of entries) {
      try {
        loaded.push(await loadOne(packDir, { registry, journal }));
      } catch (e) {
        // 一个包挂掉不许影响别的包（arch §4）—— 只记账、只标红
        const id = packDir.split(/[\\/]/).pop();
        errors.push({ id, err: String(e?.message || e) });
        journal?.({ kind: 'pack.error', id, dir: packDir, err: String(e?.message || e) });
      }
    }
  }

  return { loaded, errors };
}
