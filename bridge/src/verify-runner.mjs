// 子进程沙箱：装一个 staging 包、跑它的 tests.mjs，只回一行 JSON 给父进程。
// 独立进程本身就是护栏 —— 模型写的代码可能死循环，主进程里 eval 会连桥一起挂死；
// 父进程只管杀进程，判定留给 evolution.verify。
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const MARK = '__RESULT__';
const out = { ok: false, names: [], results: [], asserts: 0, err: '', manifest: null };

function emit() {
  process.stdout.write(MARK + JSON.stringify(out) + '\n');
  process.exit(0);
}

function pick(dir, name) {
  for (const rel of [`bridge/${name}`, name]) {
    const p = join(dir, rel);
    if (existsSync(p)) return p;
  }
  return '';
}

// 断言计数由这里数，不信任被测代码自报 —— 否则"0 断言"永远验不出来
function makeT() {
  const t = {
    count: 0,
    ok(cond, name) { t.count++; if (!cond) throw new Error(`assert failed: ${name || '(unnamed)'}`); return true; },
    eq(a, b, name) { return t.ok(Object.is(a, b) || JSON.stringify(a) === JSON.stringify(b), `${name || 'eq'}: ${JSON.stringify(a)} !== ${JSON.stringify(b)}`); },
  };
  return t;
}

async function main() {
  const dir = process.argv[2];
  if (!dir) { out.err = 'usage: verify-runner.mjs <packDir>'; return emit(); }

  const mf = join(dir, 'manifest.json');
  if (!existsSync(mf)) { out.err = 'manifest.json missing'; return emit(); }
  try {
    out.manifest = JSON.parse(readFileSync(mf, 'utf8'));
  } catch (e) {
    out.err = `manifest.json is not valid JSON: ${e.message}`;
    return emit();
  }

  const toolsFile = pick(dir, 'tools.mjs');
  if (toolsFile) {
    try {
      const mod = await import(pathToFileURL(toolsFile).href);
      const raw = mod?.default ?? mod;
      const list = Array.isArray(raw) ? raw : (raw?.tools || []);
      out.names = list.map((s) => s?.name).filter((n) => typeof n === 'string' && n);
      const bad = list.filter((s) => typeof s?.run !== 'function');
      if (bad.length) out.err = `tools without a run function: ${bad.map((s) => s?.name || '?').join(', ')}`;
    } catch (e) {
      out.err = `tools.mjs failed to import: ${e?.message || e}`;
      return emit();
    }
  }

  const testsFile = pick(dir, 'tests.mjs');
  if (!testsFile) { out.err = 'tests.mjs missing (a pack must test itself before it may be activated)'; return emit(); }

  let tests;
  try {
    const mod = await import(pathToFileURL(testsFile).href);
    const raw = mod?.default ?? mod;
    tests = Array.isArray(raw) ? raw : (raw?.tests || []);
  } catch (e) {
    out.err = `tests.mjs failed to import: ${e?.message || e}`;
    return emit();
  }
  if (!Array.isArray(tests) || tests.length === 0) { out.err = 'tests.mjs exports no tests'; return emit(); }

  for (const tc of tests) {
    const name = String(tc?.name || '(unnamed)');
    const t0 = Date.now();
    const t = makeT();
    try {
      if (typeof tc?.run !== 'function') throw new Error('test has no run function');
      await tc.run(t);
      out.asserts += t.count;
      out.results.push({ name, ok: true, ms: Date.now() - t0, err: '', asserts: t.count });
    } catch (e) {
      out.asserts += t.count;
      out.results.push({ name, ok: false, ms: Date.now() - t0, err: String(e?.message || e), asserts: t.count });
    }
  }

  out.ok = out.results.every((r) => r.ok) && out.asserts > 0 && !out.err;
  emit();
}

main().catch((e) => { out.err = String(e?.message || e); emit(); });
