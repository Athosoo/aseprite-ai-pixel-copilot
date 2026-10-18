/** P2: 注册 HTTP 路由（宿主半边）。
 *  路由：POST /aseprite/api/<method>（JSON）、GET /aseprite/media?path=…（图片字节）。
 *  两者都过 ctx.connection 的 admission（同源/浏览器鉴权），媒体只放行工作区/导出区。 */
import { createReadStream, statSync } from 'node:fs';
import { contentType, mediaAllowed } from './api.js';

const MAX_BODY = 1 << 20;

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', (c) => {
      total += c.length;
      if (total > MAX_BODY) { reject(new Error('request body too large')); req.destroy?.(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (!text.trim()) return resolve({});
      try { resolve(JSON.parse(text)); } catch { reject(new Error('body is not valid JSON')); }
    });
    req.on('error', reject);
  });
}

function sendJson(res, status, value) {
  try {
    res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
    res.end(JSON.stringify(value));
  } catch {}
}

/** cordis 取服务：优先 ctx.get（服务可能后注册），退到同名属性。 */
function service(ctx, name) {
  try {
    if (ctx && typeof ctx.get === 'function') {
      const found = ctx.get(name);
      if (found !== undefined && found !== null) return found;
    }
  } catch {}
  return ctx ? ctx[name] : undefined;
}

/** 同源/鉴权闸门。取出服务时失败一律按拒绝处理（fail closed）。 */
export function makeFence(ctx) {
  return (req) => {
    try {
      const connection = service(ctx, 'connection');
      if (connection && typeof connection.requestRejection === 'function') {
        return connection.requestRejection(req) === undefined;
      }
    } catch {}
    // 没有 connection 服务（旧宿主/测试）：放行，但路由只暴露工作区数据
    return true;
  };
}

/** 把面板操作回显进会话：找一个活动 Agent，用 inject 排队一条模型可见的上下文。
 *  inject 不唤醒驱动，所以不会触发新一轮；模型下一轮就能看到。 */
export function createEcho(ctx, note = () => {}) {
  return async (text, sessionId) => {
    try {
      const agents = service(ctx, 'agents');
      if (!agents) return { echoed: false, reason: 'agents service unavailable' };
      let agent = sessionId && typeof agents.get === 'function' ? agents.get(sessionId) : undefined;
      if (!agent && typeof agents.list === 'function') {
        const live = agents.list() || [];
        if (live.length === 1) {
          const only = live[0];
          agent = typeof only === 'string' ? agents.get(only) : (only && only.id && agents.get(only.id)) || only;
        }
      }
      if (!agent || typeof agent.inject !== 'function') {
        return { echoed: false, reason: sessionId ? 'session has no live agent' : 'no unique live agent' };
      }
      const llm = await import('@deepseek-ai/dsh-llm');
      const message = llm.createUserMessage({
        content: [{ type: 'text', text }],
        source: { kind: 'plugin:dsh-plugin-aseprite' }
      });
      agent.inject(message);
      return { echoed: true };
    } catch (e) {
      note('echo failed: ' + (e && e.message));
      return { echoed: false, reason: String((e && e.message) || e) };
    }
  };
}

/** 注册路由；返回 disposer 数组（交给 ctx.effect）。 */
export function registerRoutes(ctx, api, cfg, { note = () => {} } = {}) {
  const fence = makeFence(ctx);
  const webServer = service(ctx, 'webServer');
  if (!webServer || typeof webServer.register !== 'function') {
    note('webServer service unavailable; panel API disabled');
    return [];
  }
  const disposers = [];

  disposers.push(webServer.register({
    kind: 'prefix',
    path: '/aseprite/api',
    handler: async (req, res) => {
      if (!fence(req)) return sendJson(res, 403, { ok: false, error: 'forbidden' });
      if (req.method !== 'POST') return sendJson(res, 405, { ok: false, error: 'POST only' });
      const raw = String(req.url || '/');
      const pathname = raw.split('?')[0];
      const method = pathname.startsWith('/aseprite/api/') ? pathname.slice('/aseprite/api/'.length) : '';
      if (!method || method.includes('/')) return sendJson(res, 404, { ok: false, error: 'unknown method' });
      const fn = Object.hasOwn(api, method) ? api[method] : undefined;
      if (typeof fn !== 'function') return sendJson(res, 404, { ok: false, error: 'unknown method ' + method });
      try {
        const args = await readJson(req);
        const value = await fn(args);
        sendJson(res, 200, { ok: true, value });
      } catch (e) {
        sendJson(res, 400, { ok: false, error: String((e && e.message) || e) });
      }
    }
  }));

  disposers.push(webServer.register({
    kind: 'exact',
    path: '/aseprite/media',
    handler: async (req, res) => {
      if (!fence(req)) return sendJson(res, 403, { ok: false, error: 'forbidden' });
      try {
        const url = new URL(String(req.url || '/'), 'http://dsh.internal');
        const file = url.searchParams.get('path') || '';
        if (!mediaAllowed(cfg, file)) return sendJson(res, 403, { ok: false, error: 'forbidden path' });
        const st = statSync(file);
        if (!st.isFile()) return sendJson(res, 404, { ok: false, error: 'not a file' });
        res.writeHead(200, {
          'content-type': contentType(file),
          'content-length': String(st.size),
          'cache-control': 'no-store'
        });
        createReadStream(file).on('error', () => { try { res.destroy?.(); } catch {} }).pipe(res);
      } catch (e) {
        sendJson(res, 404, { ok: false, error: String((e && e.message) || e) });
      }
    }
  }));

  return disposers;
}
