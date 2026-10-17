// 自扩展闭环：propose → verify（子进程）→ activate（自动快照）→ rollback。
// 五条护栏（arch §6）全部实现在这个文件里；少一条，"模型能改自己"就等于没有护栏的远程执行。
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createJournal } from './journal.mjs';
import { loadPacks as defaultLoadPacks } from './packs.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const PACKS_ROOT = join(HERE, '..', 'packs');
const RUNNER = join(HERE, 'verify-runner.mjs');

export const MAX_PROPOSES_PER_TURN = 3;
export const MAX_PACK_LINES = 200;
export const MAX_PACK_BYTES = 32 * 1024;
export const KEEP_VERSIONS = 3;
export const VERIFY_TIMEOUT_MS = 5000;

const DEFAULTS = {
  packsDir: join(PACKS_ROOT, 'user'),
  stagingDir: join(PACKS_ROOT, '.staging'),
  snapDir: join(PACKS_ROOT, '.snapshots'),
  journalFile: join(PACKS_ROOT, '.journal.jsonl'),
};

// 模块级 journal(event)：§5.3 的签名就是它，默认落到 packs/.journal.jsonl
const defaultJournal = createJournal({ file: DEFAULTS.journalFile });
export function journal(event) { return defaultJournal.log(event); }

const ID_RE = /^[a-z][a-z0-9._-]{1,40}$/;

function sha1(s) { return createHash('sha1').update(s).digest('hex'); }

// 护栏 1：可写范围就是 staging 目录本身。相对路径、无 ..、解析后仍在根内 —— 三条缺一不可，
// 只查前两条的话 Windows 盘符绝对路径（C:\x）和 UNC 还能钻进来。
function insideOrThrow(root, target, what) {
  const rootAbs = resolve(root);
  const full = resolve(target);
  if (full !== rootAbs && !full.startsWith(rootAbs + sep)) {
    throw new Error(what + ' escapes the staging dir: ' + target);
  }
  return full;
}

function safeRel(rel) {
  if (typeof rel !== 'string' || rel.trim() === '') throw new Error('file path must be a non-empty string');
  if (isAbsolute(rel) || /^[a-zA-Z]:/.test(rel) || rel.startsWith('\\') || rel.startsWith('//')) {
    throw new Error('absolute paths are not writable: ' + rel);
  }
  const norm = rel.replace(/\\/g, '/');
  if (norm.split('/').some((seg) => seg === '..')) throw new Error('path escapes the staging dir: ' + rel);
  return norm;
}

export function createEvolution(opts = {}) {
  const {
    registry,
    packsDir = DEFAULTS.packsDir,
    stagingDir = DEFAULTS.stagingDir,
    snapDir = DEFAULTS.snapDir,
    maxProposes = MAX_PROPOSES_PER_TURN,
    verifyTimeoutMs = VERIFY_TIMEOUT_MS,
    maxPackLines = MAX_PACK_LINES,
    maxPackBytes = MAX_PACK_BYTES,
    keepVersions = KEEP_VERSIONS,
    loadPacks = defaultLoadPacks,
    onChanged,
    failRateLimit = 0.5,
    failRateMinCalls = 4,
  } = opts;

  let changedHandler = typeof onChanged === 'function' ? onChanged : null;
  function setChangedHandler(fn) { changedHandler = typeof fn === 'function' ? fn : null; }

  if (!registry) throw new TypeError('createEvolution: registry is required');

  const j = typeof opts.journal === 'function'
    ? opts.journal
    : (opts.journal && typeof opts.journal.log === 'function')
      ? (e) => opts.journal.log(e)
      : defaultJournal.log;

  let proposes = 0;
  let seq = 0;
  const verified = new Map();     // stagedDir -> verify 报告；activate 只认验过的
  const healthMap = new Map();    // pack id -> {calls, fails, totalMs}

  function resetTurn() { proposes = 0; }
  function budgetLeft() { return Math.max(0, maxProposes - proposes); }

  function record(packId, ms, ok) {
    if (!packId) return;
    const h = healthMap.get(packId) || { calls: 0, fails: 0, totalMs: 0 };
    h.calls++;
    if (!ok) h.fails++;
    h.totalMs += Number(ms) || 0;
    healthMap.set(packId, h);
  }

  function health() {
    const out = {};
    for (const [id, h] of healthMap) {
      out[id] = { calls: h.calls, fails: h.fails, msAvg: h.calls ? Math.round(h.totalMs / h.calls) : 0 };
    }
    return out;
  }

  function ensureDir(d) { mkdirSync(d, { recursive: true }); }

  function propose({ id, files, rationale } = {}) {
    // 护栏 5（前半）：单轮预算。先记账再判，超了就直接拒，不写任何字节。
    if (proposes >= maxProposes) {
      j({ kind: 'evolution.propose.denied', id, reason: 'budget', budgetLeft: 0 });
      return { error: 'propose budget spent for this turn (max ' + maxProposes + '); wait for the next turn', budgetLeft: 0 };
    }
    if (typeof id !== 'string' || !ID_RE.test(id)) {
      return { error: 'pack id must be lowercase letters/digits/._- and 2-41 chars: ' + JSON.stringify(id) };
    }
    if (!files || typeof files !== 'object' || Array.isArray(files)) return { error: 'files must be an object of {path: content}' };
    const names = Object.keys(files);
    if (names.length === 0) return { error: 'files is empty' };
    if (!names.some((n) => n.replace(/\\/g, '/').endsWith('manifest.json'))) {
      return { error: 'files must include manifest.json' };
    }

    // 护栏 1：路径白名单。任何一条越界就整包拒绝（不做"能写的写、不能写的跳"）。
    const rows = [];
    let bytes = 0;
    let lines = 0;
    try {
      for (const rel of names) {
        const clean = safeRel(rel);
        const content = typeof files[rel] === 'string' ? files[rel] : JSON.stringify(files[rel], null, 2);
        bytes += Buffer.byteLength(content, 'utf8');
        lines += content.split('\n').length;
        rows.push({ rel: clean, content });
      }
    } catch (e) {
      j({ kind: 'evolution.propose.denied', id, reason: 'path', err: e.message });
      return { error: String(e.message) };
    }

    // 护栏 5（后半）：单包 ≤200 行 / 32KB
    if (bytes > maxPackBytes) return { error: 'pack source is ' + bytes + ' bytes, limit is ' + maxPackBytes };
    if (lines > maxPackLines) return { error: 'pack source is ' + lines + ' lines, limit is ' + maxPackLines };

    let digest;
    try {
      const mf = JSON.parse(rows.find((r) => r.rel.endsWith('manifest.json')).content);
      if (mf.api !== 1) return { error: 'manifest.api must be 1, got ' + JSON.stringify(mf.api) };
      if (mf.id !== id) return { error: 'manifest.id must equal the proposed id (' + id + '), got ' + JSON.stringify(mf.id) };
      digest = sha1(id + '\u0000' + rows.map((r) => r.rel + '\u0000' + r.content).sort().join('\u0001'));
    } catch (e) {
      return { error: 'manifest.json is not valid JSON: ' + String(e.message) };
    }

    const staged = join(stagingDir, id + '.' + digest.slice(0, 8));
    try {
      ensureDir(stagingDir);
      for (const row of rows) {
        const dest = insideOrThrow(stagingDir, join(staged, row.rel), 'write');
        ensureDir(dirname(dest));
        writeFileSync(dest, row.content, 'utf8');
      }
    } catch (e) {
      j({ kind: 'evolution.propose.denied', id, reason: 'io', err: e.message });
      return { error: String(e.message) };
    }

    proposes++;
    j({ kind: 'evolution.propose', id, digest, staged, files: rows.map((r) => r.rel), bytes, lines, rationale: String(rationale || ''), budgetLeft: budgetLeft() });
    return { staged, digest, budgetLeft: budgetLeft() };
  }

  function runTests(staged) {
    return new Promise((done) => {
      const t0 = Date.now();
      let chunks = '';
      let settled = false;
      const finish = (payload) => {
        if (settled) return;
        settled = true;
        done(payload);
      };
      const child = spawn(process.execPath, [RUNNER, staged], { stdio: ['ignore', 'pipe', 'pipe'] });
      const timer = setTimeout(() => {
        try { child.kill('SIGKILL'); } catch { /* 已经退了 */ }
        finish({ ok: false, results: [{ name: 'tests.mjs', ok: false, ms: Date.now() - t0, err: 'hard timeout after ' + verifyTimeoutMs + 'ms' }], asserts: 0, names: [], err: 'timeout' });
      }, verifyTimeoutMs);

      child.stdout.on('data', (b) => { chunks += b.toString('utf8'); });
      child.stderr.on('data', (b) => { chunks += b.toString('utf8'); });
      child.on('error', (e) => { clearTimeout(timer); finish({ ok: false, results: [], asserts: 0, names: [], err: String(e.message) }); });
      child.on('close', () => {
        clearTimeout(timer);
        const line = chunks.split('\n').find((l) => l.startsWith('__RESULT__'));
        if (!line) {
          finish({ ok: false, results: [], asserts: 0, names: [], err: 'tests.mjs produced no result line: ' + chunks.slice(0, 400).trim() });
          return;
        }
        let parsed;
        try { parsed = JSON.parse(line.slice('__RESULT__'.length)); } catch (e) {
          finish({ ok: false, results: [], asserts: 0, names: [], err: 'unreadable result line: ' + String(e.message) });
          return;
        }
        finish(parsed);
      });
    });
  }

  async function verify({ staged } = {}) {
    if (typeof staged !== 'string' || staged === '') return { ok: false, results: [], error: 'staged is required' };
    let dir;
    try {
      dir = insideOrThrow(stagingDir, staged, 'verify');
    } catch (e) {
      return { ok: false, results: [], error: String(e.message) };
    }
    if (!existsSync(dir)) return { ok: false, results: [], error: 'staged dir does not exist: ' + dir };

    const rep = await runTests(dir);
    const manifest = rep.manifest || null;
    const rules = [];

    // 护栏 2：必须自测 —— tests.mjs 缺失或 0 断言直接不通过（不信任"我测过了"）
    rules.push({ rule: 'self-test', ok: rep.asserts > 0 && rep.results.every((r) => r.ok), detail: rep.asserts + ' assertion(s)' });

    // 护栏 3：同名 —— manifest.ops[].name 必须是本包导出的工具，或注册表里已有的工具
    const declared = Array.isArray(manifest?.ops) ? manifest.ops.map((o) => (typeof o === 'string' ? o : o?.name)).filter(Boolean) : [];
    const exported = new Set(rep.names || []);
    const missing = declared.filter((n) => {
      if (exported.has(n)) return false;
      const s = registry.get(n);
      return !(s && typeof s.run === 'function');
    });
    rules.push({ rule: 'same-name', ok: missing.length === 0, detail: missing.length ? 'not callable: ' + missing.join(', ') : declared.length + ' op(s) resolvable' });

    const ok = !!rep.ok && rules.every((r) => r.ok);
    const report = {
      ok,
      results: rep.results || [],
      asserts: rep.asserts || 0,
      names: rep.names || [],
      rules,
      error: ok ? '' : (rep.err || rules.filter((r) => !r.ok).map((r) => r.rule + ': ' + r.detail).join('; ') || 'verification failed'),
    };
    if (ok) verified.set(dir, report);
    else verified.delete(dir);
    j({ kind: 'evolution.verify', staged: dir, ok, asserts: report.asserts, error: report.error });
    return report;
  }

  function snapshotsFor(id) {
    const d = join(snapDir, id);
    if (!existsSync(d)) return [];
    return readdirSync(d)
      .filter((n) => /^\d+$/.test(n))
      .sort((a, b) => Number(b) - Number(a))
      .map((n) => join(d, n));
  }

  function snapshot(id, target) {
    ensureDir(join(snapDir, id));
    const nextSeq = seq++;
    const dest = join(snapDir, id, String(Date.now()) + String(nextSeq % 1000).padStart(3, '0'));
    cpSync(target, dest, { recursive: true });
    // 护栏 4：只保留最近 3 版 —— 无上限的快照会和日志一样把磁盘吃光
    const all = snapshotsFor(id);
    for (const old of all.slice(keepVersions)) { try { rmSync(old, { recursive: true, force: true }); } catch { /* 删不掉不影响回滚 */ } }
    return dest;
  }

  async function reload(packsRoot) {
    return loadPacks({ dirs: [packsRoot], registry, journal: j });
  }

  async function activate({ staged } = {}) {
    if (typeof staged !== 'string' || staged === '') return { error: 'staged is required' };
    let dir;
    try {
      dir = insideOrThrow(stagingDir, staged, 'activate');
    } catch (e) {
      return { error: String(e.message) };
    }
    const report = verified.get(dir);
    if (!report || !report.ok) return { error: 'pack has not passed verify() in this process', staged: dir };

    let manifest;
    try {
      manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
    } catch (e) {
      return { error: 'manifest.json unreadable: ' + String(e.message) };
    }
    const id = manifest?.id;
    if (typeof id !== 'string' || !ID_RE.test(id)) return { error: 'bad pack id: ' + JSON.stringify(id) };

    const target = join(packsDir, id);
    try { insideOrThrow(packsDir, target, 'activate'); } catch (e) { return { error: String(e.message) }; }
    ensureDir(packsDir);

    // 护栏 4：先快照再覆盖。没有上一版就不快照（首次安装无需回滚点）。
    let previous = null;
    if (existsSync(target)) {
      try { previous = snapshot(id, target); } catch (e) { return { error: 'snapshot failed, refusing to activate: ' + String(e.message) }; }
    }

    try {
      cpSync(dir, target, { recursive: true });
    } catch (e) {
      return { error: 'copy into packs dir failed: ' + String(e.message) };
    }

    const rep = await reload(packsDir);
    const bad = (rep.errors || []).find((e) => e.id === id);
    if (bad) {
      // 装上去但注册失败 = 现网已经坏了，立刻自动回退，别等 pack_health 慢慢发现
      try {
        if (previous) { rmSync(target, { recursive: true, force: true }); cpSync(previous, target, { recursive: true }); }
        else rmSync(target, { recursive: true, force: true });
      } catch { /* 回退本身失败也要如实返回 */ }
      const after = await reload(packsDir);
      j({ kind: 'evolution.activate.failed', id, err: bad.err, rolledBackTo: previous || null });
      return { error: 'load after activate failed: ' + bad.err, id, rolledBackTo: previous || null, errors: after.errors };
    }

    const info = (rep.loaded || []).find((p) => p.id === id) || null;
    verified.delete(dir);
    j({ kind: 'evolution.activate', id, previous, tools: info?.tools || [] });
    try { changedHandler?.({ id, action: 'activate' }); } catch { /* 通知失败不影响已生效的装载 */ }
    return { id, previous, tools: info?.tools || [], name: info?.name || null, version: info?.version || null };
  }

  async function rollback({ id } = {}) {
    if (typeof id !== 'string' || !ID_RE.test(id)) return { ok: false, error: 'bad pack id: ' + JSON.stringify(id) };
    const snaps = snapshotsFor(id);
    if (snaps.length === 0) return { ok: false, error: 'no snapshot for ' + id };
    const from = snaps[0];
    const target = join(packsDir, id);
    try {
      insideOrThrow(packsDir, target, 'rollback');
      rmSync(target, { recursive: true, force: true });
      cpSync(from, target, { recursive: true });
    } catch (e) {
      return { ok: false, error: String(e.message) };
    }
    rmSync(from, { recursive: true, force: true });   // 这一版已经生效，留一份就够了
    const rep = await reload(packsDir);
    j({ kind: 'evolution.rollback', id, restoredTo: from });
    try { changedHandler?.({ id, action: 'rollback' }); } catch { /* 同上 */ }
    return { ok: true, restoredTo: from, tools: (rep.loaded || []).find((p) => p.id === id)?.tools || [] };
  }

  // 现网表现反哺：失败率超阈值的**已演化包**自动回退（内置包无快照，不在此列）
  async function healthCheck() {
    const rolled = [];
    for (const [id, h] of healthMap) {
      if (h.calls < failRateMinCalls) continue;
      if (h.fails / h.calls <= failRateLimit) continue;
      const rep = await rollback({ id });
      if (rep.ok) rolled.push({ id, restoredTo: rep.restoredTo });
      else j({ kind: 'evolution.health.unrollbackable', id, error: rep.error, calls: h.calls, fails: h.fails });
    }
    return rolled;
  }

  return {
    propose, verify, activate, rollback, health, healthCheck,
    record, resetTurn, budgetLeft, setChangedHandler,
    stats: () => ({ budgetLeft: budgetLeft(), verified: verified.size, packsDir, stagingDir, snapDir, maxProposes, verifyTimeoutMs }),
  };
}
