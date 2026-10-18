/** 客户端 bundle 冒烟：没有浏览器也能验证"外层壳 + 工厂 + 两个插槽注册"没坏。
 *  react 用最小 stub（注册阶段只需要 createElement 存在）。 */
import { strict as assert } from 'node:assert';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const CODE = readFileSync(fileURLToPath(new URL('../client/client.js', import.meta.url)), 'utf8');

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); pass++; console.log('  ok   ' + name); }
  catch (e) { fail++; console.log('  FAIL ' + name + '   <- ' + e.message); }
}

const react = {
  createElement: (type, props, ...children) => ({ type, props: props || {}, children }),
  useState: (v) => [v, () => {}],
  useEffect: () => {},
  useCallback: (f) => f,
  useMemo: (f) => f()
};

let loaded = null;
const sandbox = {
  window: { __ModuleLoader__: { load: (m) => { loaded = m; } } },
  document: { baseURI: 'http://localhost:1234/' },
  console, URL, fetch: async () => ({ status: 200, json: async () => ({ ok: true, value: {} }) })
};

vm.runInNewContext(CODE, sandbox, { filename: 'client/client.js' });

check('外层壳调用 load 一次', () => assert.ok(loaded && loaded.id === 'dsh-plugin-aseprite'));
check('factory 导出 name / apply / inject', () => {
  const mod = loaded.factory((name) => (name === 'react' ? react : {}));
  assert.equal(mod.name, 'dsh-plugin-aseprite');
  assert.equal(typeof mod.apply, 'function');
  assert.equal(mod.inject.length, 1);
  assert.equal(mod.inject[0], 'slots');
});

check('apply 注册侧边栏条目 + 主区页面', () => {
  const mod = loaded.factory((name) => (name === 'react' ? react : {}));
  const took = [];
  const ctx = {
    get: () => undefined,
    slots: {
      inject: (name, fn) => { fn(); },
      register: (spec, comp) => { took.push({ spec, comp }); return () => {}; }
    }
  };
  mod.apply(ctx);
  assert.equal(took.length, 2);
  assert.equal(took[0].spec.name, 'sidebar.panellist');
  assert.equal(took[0].spec.order, 40);
  assert.equal(took[1].spec.name, 'main');
  assert.equal(took[1].spec.key, 'aseprite-workbench');
  assert.equal(typeof took[1].comp, 'function');
});

check('PanelPage 能渲染成树（不抛错）', () => {
  const mod = loaded.factory((name) => (name === 'react' ? react : {}));
  let page = null;
  const ctx = {
    get: () => undefined,
    slots: { inject: (n, f) => f(), register: (spec, comp) => { if (spec.name === 'main') page = comp; return () => {}; } }
  };
  mod.apply(ctx);
  const tree = page();
  assert.equal(tree.type, 'div');
  assert.ok(tree.children.length > 0);
});

console.log('\n==== client-load: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
