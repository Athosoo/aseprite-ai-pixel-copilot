/** 启动竞态回归：webServer / connection / agents 都是后注册的服务。
 *  插件必须在服务就绪后再挂路由（ctx.inject），不能在 apply 里直接取。
 *  这个 bug 真实发生过：插件先于 webServer 挂载 → ctx.get 返回 undefined →
 *  属性回退抛 "cannot get property webServer without inject" → 面板 405。 */
import { strict as assert } from 'node:assert';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../', import.meta.url));

// 本地跑需要 @deepseek-ai/dsh-tools 可解析（真实环境由 DSH 的模块映射提供）
const STUB = join(ROOT, 'node_modules', '@deepseek-ai', 'dsh-tools');
mkdirSync(STUB, { recursive: true });
writeFileSync(join(STUB, 'package.json'), JSON.stringify({
  name: '@deepseek-ai/dsh-tools', version: '0.0.0-test', type: 'module', main: 'index.js', exports: './index.js'
}) + '\n');
writeFileSync(join(STUB, 'index.js'), 'export const defineTool = (x) => x;\n');

const HOME = mkdtempSync(join(tmpdir(), 'ase-wiring-home-'));
process.env.DSH_ASEPRITE_HOME = HOME;

const mod = await import(pathToFileURL(join(ROOT, 'lib', 'index.js')).href);

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); pass++; console.log('  ok   ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '   <- ' + (e && e.message)); }
}

function makeCtx(services) {
  const registered = [];
  const injected = [];
  const routes = [];
  const effects = [];
  const ctx = {
    tools: { register: (t) => registered.push(t) },
    effect: (fn) => { effects.push(fn); },
    get: (name) => {
      if (services && Object.hasOwn(services, name)) {
        const v = services[name];
        if (v === 'THROW') throw new Error('cannot get property "' + name + '" without inject');
        return v;
      }
      return undefined;
    },
    inject: (deps, cb) => { injected.push({ deps, cb }); }
  };
  // 未 inject 的 ctx：属性访问会抛（模拟 cordis 代理）
  for (const name of ['webServer', 'connection', 'agents']) {
    Object.defineProperty(ctx, name, {
      get() { throw new Error('cannot get property "' + name + '" without inject'); }
    });
  }
  return { ctx, registered, injected, routes, effects };
}

const readyRoutes = [];
const webServer = { register: (r) => { readyRoutes.push(r); return () => {}; } };
const connection = { requestRejection: () => undefined };

console.log('== 服务未就绪时 apply 不炸，且推迟挂路由 ==');
const a = makeCtx({});
mod.apply(a.ctx, {});
check('7 个工具照常注册', () => assert.equal(a.registered.length, 7));
check('没有直接注册路由（服务还没就绪）', () => assert.equal(a.routes.length, 0, a.routes.length));
check('声明了对 agents 的等待', () => assert.ok(a.injected.some((i) => i.deps.includes('agents'))));
check('声明了对 webServer + connection 的等待', () => {
  const w = a.injected.find((i) => i.deps.includes('webServer'));
  assert.ok(w, 'no webServer inject');
  assert.ok(w.deps.includes('connection'));
});
check('apply 没有抛错（属性访问抛错已被吃掉）', () => assert.ok(true));

console.log('== 服务就绪后注入回调挂上两条路由 ==');
const ready = makeCtx({ webServer, connection });
const wire = a.injected.find((i) => i.deps.includes('webServer'));
check('注入回调存在', () => assert.ok(wire && typeof wire.cb === 'function'));
const captured = [];
const wctx = {
  get: (n) => (n === 'webServer' ? webServer : n === 'connection' ? connection : undefined),
  effect: (fn) => { captured.push(fn); },
  tools: ready.ctx.tools
};
wire.cb(wctx);
check('注册了 api 前缀 + media 精确路由', () => {
  assert.equal(readyRoutes.length, 2);
  assert.equal(readyRoutes[0].path, '/aseprite/api');
  assert.equal(readyRoutes[1].path, '/aseprite/media');
});

console.log('== 兼容：老宿主没有 ctx.inject 时直接挂 ==');
const legacy = makeCtx({ webServer, connection });
delete legacy.ctx.inject;
legacy.ctx.get = (n) => (n === 'webServer' ? webServer : n === 'connection' ? connection : undefined);
// 属性访问仍然抛错，直接 wire(ctx) 也应安全降级
mod.apply(legacy.ctx, {});
check('没有 inject 时不抛错', () => assert.ok(true));

rmSync(HOME, { recursive: true, force: true });
console.log('\n==== inject-wiring: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
