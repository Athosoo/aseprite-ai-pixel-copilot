/** P2 面板 API 单测：目录列举 / 预览落点 / 媒体白名单 / 路由信封 / 回显降级。
 *  不需要 Aseprite（需要真机的那部分在 smoke.mjs）。 */
import { strict as assert } from 'node:assert';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { Readable } from 'node:stream';
import { createApi, listSpriteFiles, mediaAllowed, previewTarget } from '../lib/api.js';
import { createEcho, makeFence, registerRoutes } from '../lib/routes.js';
import { loadConfig } from '../lib/config.js';

let pass = 0, fail = 0;
function check(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => { pass++; console.log('  ok   ' + name); })
    .catch((e) => { fail++; console.log('  FAIL ' + name + '   <- ' + (e && e.message)); });
}

const HOME = mkdtempSync(join(tmpdir(), 'ase-api-home-'));
process.env.DSH_ASEPRITE_HOME = HOME;
const cfg = loadConfig();
mkdirSync(cfg.workspace, { recursive: true });
mkdirSync(cfg.exportDir, { recursive: true });
writeFileSync(join(cfg.workspace, 'hero.ase'), 'x');
writeFileSync(join(cfg.workspace, 'icon.png'), 'png');
writeFileSync(join(cfg.workspace, 'notes.txt'), 'n');
mkdirSync(join(cfg.workspace, 'sub'), { recursive: true });
writeFileSync(join(cfg.workspace, 'sub', 'deep.png'), 'd');

const manifest = [
  { name: 'contrast', desc: 'contrast op', params: [{ name: 'amount', type: 'number', default: 1.3, desc: 'a' }] },
  { name: 'sharpen', desc: 'sharpen op', params: [{ name: 'amount', type: 'number', default: 1, desc: 'a' }] }
];
const api = createApi({}, cfg, manifest, { echo: async () => ({ echoed: false, reason: 'disabled' }) });

console.log('== 文件列举 ==');
await check('listSpriteFiles 只列精灵文件并按名字排序', () => {
  const r = listSpriteFiles(cfg, '.');
  assert.deepEqual(r.files.map((f) => f.name), ['hero.ase', 'icon.png']);
  assert.ok(r.files.every((f) => f.size >= 0 && f.mtime > 0));
});
await check('listSpriteFiles 支持子目录', () => assert.deepEqual(listSpriteFiles(cfg, 'sub').files.map((f) => f.name), ['deep.png']));
await check('工作区外目录被拒绝', () => assert.throws(() => listSpriteFiles(cfg, 'C:/Windows'), /outside the workspace/));

console.log('== 预览 ==');
await check('png 源直接走媒体路由（不调 Aseprite）', async () => {
  const r = await api.preview({ file: 'icon.png' });
  assert.equal(r.via, 'png');
  assert.ok(r.path.endsWith('icon.png'));
});
await check('预览落点在工作区 _preview 下且按路径区分', () => {
  const a = previewTarget(cfg, join(cfg.workspace, 'hero.ase'));
  const b = previewTarget(cfg, join(cfg.workspace, 'sub', 'deep.png'));
  assert.ok(a.includes('_preview'));
  assert.notEqual(a, b);
});
await check('不存在的文件报错', async () => {
  await assert.rejects(() => api.preview({ file: 'nope.ase' }), /no such file/);
});

console.log('== 媒体白名单 ==');
await check('工作区内的文件允许', () => assert.equal(mediaAllowed(cfg, join(cfg.workspace, 'icon.png')), true));
await check('导出区内的文件允许', () => assert.equal(mediaAllowed(cfg, join(cfg.exportDir, 'x.png')), true));
await check('工作区外的文件拒绝', () => assert.equal(mediaAllowed(cfg, 'C:/Windows/win.ini'), false));
await check('相对路径拒绝', () => assert.equal(mediaAllowed(cfg, 'icon.png'), false));

console.log('== API 表 ==');
await check('state 带出工作区/算子/文件', async () => {
  const s = await api.state();
  assert.equal(s.workspace, cfg.workspace);
  assert.equal(s.ops.length, 2);
  assert.deepEqual(s.files.map((f) => f.name), ['hero.ase', 'icon.png']);
});
await check('apply 没给算子时报错', async () => {
  await assert.rejects(() => api.apply({ file: 'hero.ase' }), /no operations given/);
});
await check('apply 目标在工作区外被拒绝', async () => {
  await assert.rejects(() => api.apply({ file: 'C:/Windows/system32/evil.ase', op: 'contrast' }), /outside the workspace/);
});

console.log('== HTTP 路由 ==');
function fakeRes() {
  return {
    statusCode: 0, headers: {}, body: '',
    writeHead(code, headers) { this.statusCode = code; Object.assign(this.headers, headers || {}); },
    end(body) { this.body = body || ''; },
    destroy() {}
  };
}
function fakeReq(method, url, body) {
  const req = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
  req.method = method; req.url = url; req.headers = {};
  return req;
}
const routes = [];
const fakeCtx = { webServer: { register: (r) => { routes.push(r); return () => {}; } } };
registerRoutes(fakeCtx, api, cfg, {});
await check('注册了 api 前缀 + media 精确路由', () => {
  assert.equal(routes.length, 2);
  assert.equal(routes[0].kind, 'prefix');
  assert.equal(routes[0].path, '/aseprite/api');
  assert.equal(routes[1].path, '/aseprite/media');
});
await check('POST state 返回 {ok:true,value}', async () => {
  const res = fakeRes();
  await routes[0].handler(fakeReq('POST', '/aseprite/api/state', {}), res);
  const payload = JSON.parse(res.body);
  assert.equal(res.statusCode, 200);
  assert.equal(payload.ok, true);
  assert.equal(payload.value.ops.length, 2);
});
await check('未知方法 404', async () => {
  const res = fakeRes();
  await routes[0].handler(fakeReq('POST', '/aseprite/api/constructor', {}), res);
  assert.equal(res.statusCode, 404);
  assert.equal(JSON.parse(res.body).ok, false);
});
await check('非 POST 405', async () => {
  const res = fakeRes();
  await routes[0].handler(fakeReq('GET', '/aseprite/api/state'), res);
  assert.equal(res.statusCode, 405);
});
await check('非法 JSON 400 且不崩', async () => {
  const res = fakeRes();
  const req = Readable.from([Buffer.from('{oops')]);
  req.method = 'POST'; req.url = '/aseprite/api/state'; req.headers = {};
  await routes[0].handler(req, res);
  assert.equal(res.statusCode, 400);
});
await check('media 拒绝工作区外路径', async () => {
  const res = fakeRes();
  await routes[1].handler(fakeReq('GET', '/aseprite/media?path=' + encodeURIComponent('C:/Windows/win.ini')), res);
  assert.equal(res.statusCode, 403);
});
await check('fence 在 connection 服务拒绝时返回 false', () => {
  const fence = makeFence({ get: () => ({ requestRejection: () => ({ code: 403 }) }) });
  assert.equal(fence({ method: 'POST', url: '/', headers: {} }), false);
});
await check('没有 connection 服务时放行（fail-open 仅限本地）', () => {
  assert.equal(makeFence({}) ({ method: 'POST', url: '/', headers: {} }), true);
});

console.log('== 回显 ==');
await check('没有 agents 服务时优雅降级', async () => {
  const echoed = await createEcho({ get: () => undefined })({}, 'x');
  assert.equal(echoed.echoed, false);
  assert.match(echoed.reason, /agents service unavailable/);
});
await check('会话没有活动 agent 时降级', async () => {
  const ctx = { get: (n) => (n === 'agents' ? { get: () => undefined, list: () => [] } : undefined) };
  const r = await createEcho(ctx)('t', 'session-1');
  assert.equal(r.echoed, false);
  assert.match(r.reason, /no live agent/);
});
await check('单活 agent + 拿不到 dsh-llm 时不抛，只报 echoed:false', async () => {
  const agent = { id: 'a1', inject() {} };
  const ctx = { get: (n) => (n === 'agents' ? { get: (id) => (id === 'a1' ? agent : undefined), list: () => [agent] } : undefined) };
  const r = await createEcho(ctx)('t');
  // 本机没有 @deepseek-ai/dsh-llm：动态 import 失败 -> 走 catch
  assert.equal(r.echoed, false);
});

rmSync(HOME, { recursive: true, force: true });
console.log('\n==== api: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
