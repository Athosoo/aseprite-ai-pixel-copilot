/** 用假 ctx 验证注册：不启动 DSH，也能发现「工具没注册 / 名字写错 / 说明为空」。
 *  跑法（在插件目录）：PLUGIN_PATH=<插件绝对路径> node test/register-check.mjs
 *  注意：@deepseek-ai/dsh-tools 只有在 DSH 自己的模块映射里才解析得到；
 *  本地跑需要临时放一个 stub（见 README 的说明），否则会是 ERR_MODULE_NOT_FOUND。 */
import { pathToFileURL } from 'node:url';
import { strict as assert } from 'node:assert';

const mod = await import(pathToFileURL(process.env.PLUGIN_PATH + '/lib/index.js').href);
const registered = [];
const fakeCtx = { tools: { register: (t) => { registered.push(t); } } };
mod.apply(fakeCtx, {});

const names = registered.map((t) => t.name);
console.log('name=' + mod.name + ' apply=' + typeof mod.apply);
console.log('registered=' + JSON.stringify(names));

const EXPECTED = ['aseprite_config', 'aseprite_status', 'aseprite_ops', 'aseprite_ls',
  'aseprite_apply', 'aseprite_export', 'aseprite_open'];
assert.deepEqual(names, EXPECTED, 'tool list changed: ' + names.join(','));
for (const t of registered) assert.ok(t.description && t.description.length > 10, t.name + ': empty description');
const applyTool = registered.find((t) => t.name === 'aseprite_apply');
assert.match(applyTool.description, /Available operators/, 'apply description must embed the op list');
assert.match(applyTool.description, /contrast/, 'apply description must mention contrast');
console.log('ok: 7 tools, descriptions present, op list embedded');
