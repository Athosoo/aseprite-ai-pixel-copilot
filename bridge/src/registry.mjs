// 工具注册表 —— 内核只认这张表，不再认任何写死的工具数组。
// 判据（arch §1）：加一项能力要不要改这个文件？不要，才算分层对了。
import { createHash } from 'node:crypto';

const EMPTY_SCHEMA = { type: 'object', properties: {}, required: [] };

export function createRegistry({ journal } = {}) {
  const specs = new Map();
  let fp = '';
  // 注册失败不能把调用方（包加载）也一起拉黑，所以账本异常一律吞掉
  const note = (evt) => { try { journal?.({ ...evt, at: Date.now() }); } catch { /* 账本不可用不影响注册 */ } };

  function define(spec) {
    if (!spec || typeof spec !== 'object') throw new TypeError('registry.define: spec must be an object');
    if (!spec.name || typeof spec.name !== 'string') throw new TypeError('registry.define: spec.name is required');
    if (typeof spec.run !== 'function') throw new TypeError(`registry.define: ${spec.name}.run must be a function`);

    const prev = specs.get(spec.name);
    const next = {
      name: spec.name,
      description: String(spec.description || ''),
      inputSchema: spec.inputSchema || EMPTY_SCHEMA,
      run: spec.run,
      pack: spec.pack || 'builtin',
      // since：这个工具第一次由谁提供（回滚后要靠它认出来源）；evolved：是否被后来的包覆盖过
      meta: {
        since: prev?.meta?.since || spec.meta?.since || '',
        evolved: prev ? (spec.meta?.evolved ?? true) : (spec.meta?.evolved ?? false),
      },
    };
    // expose:false 用于"内核自己用、不给模型看"的条目（如 gaps_info 走 WS 帧，不进 prompt）
    if (spec.expose === false) next.expose = false;

    specs.set(spec.name, next);
    fp = '';
    note({ kind: prev ? 'registry.override' : 'registry.define', name: next.name, pack: next.pack });
    return next;
  }

  function list() { return [...specs.values()]; }
  function get(name) { return specs.get(name) || null; }
  function remove(name) {
    const had = specs.delete(name);
    if (had) { fp = ''; note({ kind: 'registry.remove', name }); }
    return had;
  }

  // 指纹 = 模型真正看得见的那几个字段（名字/来源/说明/schema）。
  // 刻意不含实现体：实现换了但签名没变就不该重发工具表（arch §6 懒构造）；
  // 也不含 meta：来源与演化历史给 list_capabilities 用，进指纹只会造成无谓的抖动。
  function fingerprint() {
    if (fp) return fp;
    const h = createHash('sha1');
    for (const s of specs.values()) {
      h.update(s.name + '\u0000' + s.pack + '\u0000' + s.description + '\u0000' + JSON.stringify(s.inputSchema) + '\n');
    }
    fp = h.digest('hex');
    return fp;
  }

  return { define, list, get, remove, fingerprint, size: () => specs.size };
}
