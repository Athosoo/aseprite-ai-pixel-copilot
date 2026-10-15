// 本地桥：WebSocket 服务 + OpenAI 兼容 LLM + 工具注册表 + 色值库
//
//   Aseprite(Lua 扩展) <--WebSocket--> 本进程 <--HTTPS--> LLM
//
// 启： node src/server.mjs        （或在 Aseprite 里打开面板，会自动拉起）
// 查： 浏览器打开 http://127.0.0.1:8777/health

import { WebSocketServer } from 'ws';
import { createServer } from 'node:http';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { ColorBank } from './colorbank.mjs';
import { Memory } from './memory.mjs';
import { Styles } from './styles.mjs';
import { TOOLS, makeDispatcher } from './tools.mjs';
import { runTurn, chatCompletion } from './llm.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

// ---------------------------------------------------------------- 配置
const argv = process.argv.slice(2);
const argConfig = (() => {
  const i = argv.indexOf('--config');
  return i >= 0 ? argv[i + 1] : null;
})();
const CONFIG_PATH = argConfig
  ? (argConfig.match(/^[A-Za-z]:[\\/]/) ? argConfig : join(process.cwd(), argConfig))
  : join(ROOT, 'config.json');
const EXAMPLE_PATH = join(ROOT, 'config.example.json');

if (!existsSync(CONFIG_PATH)) {
  if (existsSync(EXAMPLE_PATH)) {
    writeFileSync(CONFIG_PATH, readFileSync(EXAMPLE_PATH, 'utf8'), 'utf8');
    console.log(`[bridge] Created config.json from config.example.json -- fill in llm.apiKey and restart.`);
  } else {
    console.error(`[bridge] Neither config.json nor config.example.json found; cannot start.`);
    process.exit(1);
  }
}
const cfg = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
const PORT = Number(cfg.port || 8777);
const BUNDLE = join(ROOT, cfg.paths?.perfectPixelBundle || 'vendor/perfectPixel.mjs');
const SYSTEM_PROMPT = cfg.systemPrompt || '你是一个像素画助手。';

const BANK_PATH = join(ROOT, cfg.paths?.colorBank || 'data/colors.json');
const bank = new ColorBank(BANK_PATH);

// 通用记忆库（配色方案 / 风格偏好 / 项目约定…）。和色值库分开存，
// 但同一个 data/ 目录，方便用户直接翻看、手工编辑。
const MEMORY_PATH = join(ROOT, cfg.paths?.memory || 'data/memory.json');
const memory = new Memory(MEMORY_PATH);

// 风格库：调色板 + 图层结构 + 作画规矩的模板。切换风格时**只注入当前那一个**，
// 不是把整库塞进 prompt —— 这是省 token 的关键。
const styles = new Styles({
  builtinDir: join(ROOT, cfg.paths?.styles || 'styles'),
  userDir: join(ROOT, 'data', 'styles'),
});
// 当前风格名持久化在 config.json 里，重启桥也记得
let activeStyle = cfg.activeStyle || '';

// ------------------------------------------------------- 配置读写（供插件内设置面板用）
// 只把"是否已设置 + 掩码提示"发给 Aseprite，绝不外传完整 key。
function maskKey(k) {
  if (!k) return '';
  if (k.length <= 8) return '****';
  return `${k.slice(0, 3)}****${k.slice(-4)}`;
}

function configPayload() {
  return {
    type: 'config',
    llm: {
      baseUrl: cfg.llm?.baseUrl || '',
      model: cfg.llm?.model || '',
      apiKeySet: !!cfg.llm?.apiKey,
      apiKeyHint: maskKey(cfg.llm?.apiKey),
    },
    port: PORT,
    colorBank: BANK_PATH,
    perfectPixelReady: existsSync(BUNDLE),
    workspace: { root: cfg.workspace?.root || '' },
    ui: {
      mode: cfg.ui?.mode || 'panel',
      barBg: cfg.ui?.barBg || '',
    },
  };
}

// 写回 config.json：保留 systemPrompt 等其它字段，只更新 llm 段。
function saveConfig() {
  const raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
  raw.llm = { ...(raw.llm || {}), ...cfg.llm };
  if (cfg.workspace) raw.workspace = { ...(raw.workspace || {}), ...cfg.workspace };
  if (cfg.ui) raw.ui = { ...(raw.ui || {}), ...cfg.ui };
  writeFileSync(CONFIG_PATH, JSON.stringify(raw, null, 2), 'utf8');
}

// ---------------------------------------------------------------- 会话
class Session {
  constructor(ws) {
    this.ws = ws;
    this.seq = 0;
    this.pending = new Map();
    this.pendingBinary = null; // 等待二进制负载的头部
    this.upload = null;        // 最近一次上传的图片
    this.history = [];         // 对话历史
    this.busy = false;
    this.queue = [];
    this.info = {};
    this.turnAbort = null;     // 当前这一轮的中断控制器（P3）
    this.turnProcessed = new Set();  // 本轮已经处理过的图片来源（P8 防复读）
  }

  send(obj) {
    if (this.ws.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  // i18nKey 有值时，面板会用本地化文案覆盖 text（P3 的中断提示等）
  say(kind, text, i18nKey) {
    this.send({ type: 'say', kind, text, i18n: i18nKey });
  }

  status(text, kind) {
    this.send({ type: 'status', text, kind });
  }

  request(kind, payload = {}, timeoutMs = 60000) {
    const id = ++this.seq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`等待 Aseprite 响应超时：${kind}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
      this.send({ type: kind, id, ...payload });
    });
  }

  resolvePending(id, value) {
    const p = this.pending.get(id);
    if (p) {
      this.pending.delete(id);
      p.resolve(value);
    }
  }

  sendImport(data, width, height, note) {
    this.send({ type: 'import_image', id: ++this.seq, width, height, note });
    this.ws.send(Buffer.from(data.buffer, data.byteOffset, data.byteLength), { binary: true });
  }

  // 收到一个用户指令，串行处理（同一时间只跑一轮对话）
  enqueueChat(text, context) {
    this.queue.push({ text, context });
    if (!this.busy) this.drain();
  }

  async drain() {
    this.busy = true;
    while (this.queue.length) {
      const job = this.queue.shift();
      await this.handleChat(job.text, job.context);
    }
    this.busy = false;
  }

  async handleChat(text, context) {
    if (!cfg.llm?.apiKey) {
      this.say('error', 'No API key configured. Click Settings in the panel and paste one.');
      this.status('missing API key', 'error');
      return;
    }

    // 轮级中断（P3）：面板「停止」/ Esc 发 {type:'abort'}，超时也走同一个控制器。
    // 单次 HTTP 超时（chatCompletion 内部）< 整轮超时（这里），层级不同。
    const ac = new AbortController();
    this.turnAbort = ac;
    this.turnProcessed = new Set();
    const maxTurnMs = cfg.llm?.maxTurnMs ?? 180000;
    const turnTimer = setTimeout(() => ac.abort('timeout'), maxTurnMs);

    try {
      const dispatch = makeDispatcher({
        session: this, bank, memory, styles, cfg, bundlePath: BUNDLE,
        getActiveStyle: () => activeStyle,
        setActiveStyle: (n) => {
          activeStyle = n || '';
          try {
            const raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
            raw.activeStyle = activeStyle;
            writeFileSync(CONFIG_PATH, JSON.stringify(raw, null, 2), 'utf8');
          } catch { /* 存不下来不影响本次会话 */ }
        },
      });

      // 只把【当前】风格的约束拼在系统提示后面。没选风格就一个字都不加。
      // 传的是函数：模型在同一轮里 style_use 换了风格，后面的步骤立刻按新风格来。
      const buildSystemPrompt = () => {
        const styleText = activeStyle ? styles.describe(activeStyle) : null;
        return styleText ? `${SYSTEM_PROMPT}\n\n${styleText}` : SYSTEM_PROMPT;
      };
      await runTurn({
        cfg: cfg.llm,
        systemPrompt: buildSystemPrompt,
        history: this.history,
        userText: text,
        context,
        tools: TOOLS,
        dispatch,
        abortSignal: ac.signal,
        onSay: (kind, t, key) => this.say(kind, t, key),
        onStatus: (t, kind) => this.status(t, kind),
      });
      // 只保留最近若干轮，避免上下文无限增长
      this.history = this.history.slice(-12);
    } catch (e) {
      if (e?.name === 'TurnAborted') {
        // 中断不是错误：手动和超时给不同的提示
        if (e.reason === 'timeout') this.say('info', 'Task timed out and was interrupted automatically.', 'abortTimeout');
        else this.say('info', 'Task interrupted.', 'aborted');
      } else {
        this.say('error', `Error: ${e?.message || e}`);
      }
      this.status('ready', 'ok');
    } finally {
      clearTimeout(turnTimer);
      this.turnAbort = null;
      this.turnProcessed = new Set();
    }
  }

  // 面板按了「停止」/ Esc（P3）。中断是"尽力而为"：没有在跑的任务就当无事发生。
  abortTurn() {
    if (!this.turnAbort) {
      this.say('info', 'Nothing is running right now.', 'abortNothing');
      return;
    }
    this.turnAbort.abort('user');
  }

  // 用当前配置做一次最小请求，验证 baseUrl / apiKey / model 是否可用
  async testLlm() {
    if (!cfg.llm?.apiKey) {
      this.say('error', 'Test failed: no API key set yet.');
      return;
    }
    const t0 = Date.now();
    this.status('testing LLM...', 'busy');
    try {
      const r = await chatCompletion(cfg.llm, [
        { role: 'user', content: 'Reply with exactly: pong' },
      ], null);
      const text = String(r.choices?.[0]?.message?.content || '').trim().slice(0, 80);
      this.say('ai', `Connection OK in ${Date.now() - t0} ms -- model "${cfg.llm.model}" replied: ${text || '(empty)'}`);
    } catch (e) {
      this.say('error', `Connection failed: ${e?.message || e}`);
    }
    this.status('ready', 'ok');
  }

  onText(msg) {
    switch (msg.type) {
      case 'hello': {
        this.info = msg;
        this.say('info', `Bridge ready. Aseprite ${msg.aseprite}, ${(msg.ops || []).length} ops available.`);
        this.status('ready', 'ok');
        this.send(configPayload());
        if (!cfg.llm?.apiKey) {
          this.say('info', 'No API key yet -- click Settings in the panel to paste one.');
        }
        break;
      }

      case 'get_config':
        this.send(configPayload());
        break;

      case 'set_config': {
        const llm = msg.llm || {};
        if (typeof llm.baseUrl === 'string' && llm.baseUrl.trim()) cfg.llm.baseUrl = llm.baseUrl.trim();
        if (typeof llm.model === 'string' && llm.model.trim()) cfg.llm.model = llm.model.trim();
        // 空 apiKey = 保持不变（面板里不回显真 key）
        if (llm.clearApiKey) cfg.llm.apiKey = '';
        else if (typeof llm.apiKey === 'string' && llm.apiKey.trim()) cfg.llm.apiKey = llm.apiKey.trim();
        // 工作区根目录（P10）：空字符串 = 关闭工作区模式
        if (typeof msg.workspace?.root === 'string') {
          cfg.workspace = { ...(cfg.workspace || {}), root: msg.workspace.root.trim() };
        }
        // 界面形态 / 栏底色（G3 / G5）：改完落盘，重启桥和重启 Aseprite 都记得
        if (typeof msg.ui?.mode === 'string') {
          cfg.ui = { ...(cfg.ui || {}), mode: msg.ui.mode.trim() };
        }
        if (typeof msg.ui?.barBg === 'string') {
          cfg.ui = { ...(cfg.ui || {}), barBg: msg.ui.barBg.trim() };
        }
        try {
          saveConfig();
          this.say('info', 'Settings saved to bridge/config.json (effective immediately).');
        } catch (e) {
          this.say('error', `Could not write config.json: ${e?.message || e}`);
        }
        this.send(configPayload());
        break;
      }

      case 'test_llm':
        this.testLlm();
        break;
      case 'abort':
        this.abortTurn();
        break;
      case 'chat':
        this.enqueueChat(msg.text || '', msg.context || {});
        break;
      case 'upload':
        this.pendingBinary = { ...msg, kind: 'upload' };
        break;
      case 'canvas_pixels':
        this.pendingBinary = { ...msg, kind: 'canvas_pixels' };
        break;
      case 'ops_result':
        this.resolvePending(msg.id, msg.ok ? { ok: true, ...msg.report } : { error: msg.error });
        break;
      case 'size_result':
        // 裁剪 / 整体缩放 / 改画布尺寸共用这一个结果类型
        this.resolvePending(msg.id, msg.ok ? { ok: true, ...msg.report } : { error: msg.error });
        break;
      case 'art_result':
        // 新建文档 / 建图层 / 字符网格作画共用
        this.resolvePending(msg.id, msg.ok ? { ok: true, ...msg.report } : { error: msg.error });
        break;
      case 'snapshot_result':
        this.resolvePending(msg.id, msg.ok ? { ok: true, ...msg.meta } : { error: msg.error });
        break;
      case 'rollback_result':
        this.resolvePending(msg.id, msg.ok ? { ok: true, ...msg.report } : { error: msg.error });
        break;
      case 'versions':
        this.resolvePending(msg.id, { ok: true, versions: msg.list });
        break;
      case 'canvas_info_result':
        this.resolvePending(msg.id, msg.context || {});
        break;
      case 'request_error':
        this.resolvePending(msg.id, { error: msg.error || 'Aseprite 侧拒绝了请求' });
        break;
      case 'open_doc_result':
        this.resolvePending(msg.id, msg.ok
          ? { ok: true, name: msg.name, path: msg.path, width: msg.width, height: msg.height }
          : { error: msg.error || 'open failed' });
        break;
      case 'workspace_result':
        this.resolvePending(msg.id, { ok: true, root: msg.root, files: msg.files || [] });
        break;
      case 'edit_blocked':
        // 工作区准备失败 -> 这次编辑被中止，直接推给用户看（工具那边也会拿到错误）
        this.say('error', msg.error || 'The edit was blocked by the workspace.');
        break;
      case 'answer':
        // P7：面板弹出的选项被点了（或用户取消了）。工具结果原样回到模型上下文。
        this.resolvePending(msg.id, msg.cancelled
          ? { cancelled: true }
          : { ok: true, choice: msg.choice, index: msg.index });
        break;
      default:
        console.log('[bridge] unhandled message', msg.type);
    }
  }

  onBinary(buf) {
    const header = this.pendingBinary;
    this.pendingBinary = null;
    if (!header) {
      console.log('[bridge] binary frame without a header, ignored');
      return;
    }
    if (header.kind === 'upload') {
      this.upload = { buf, w: header.width, h: header.height, name: header.name || '(未命名)' };
      this.say('info', `Received image ${header.name} (${header.width}x${header.height}). Say "fix this image".`);
      this.status('ready', 'ok');
    } else if (header.kind === 'canvas_pixels') {
      this.resolvePending(header.id, { buf, width: header.width, height: header.height });
    }
  }
}

// ---------------------------------------------------------------- 服务
const httpServer = createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, port: PORT, clients: sessions.size, keyConfigured: !!cfg.llm?.apiKey }));
    return;
  }
  res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('AI Pixel Copilot bridge is running.\nTry /health\n');
});

const wss = new WebSocketServer({ server: httpServer });
const sessions = new Set();

wss.on('connection', (ws) => {
  const session = new Session(ws);
  sessions.add(session);
  console.log('[bridge] Aseprite connected');
  session.status('connected, waiting for input', 'ok');

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      session.onBinary(data);
      return;
    }
    let msg;
    try {
      msg = JSON.parse(data.toString('utf8'));
    } catch {
      console.log('[bridge] unparseable text frame');
      return;
    }
    session.onText(msg);
  });

  ws.on('close', () => {
    sessions.delete(session);
    console.log('[bridge] Aseprite disconnected');
  });

  ws.on('error', (e) => console.log('[bridge] socket error:', e.message));
});

httpServer.on('error', (e) => {
  if (e.code === 'EADDRINUSE') {
    console.log(`[bridge] Port ${PORT} already in use -- the bridge is probably already running. Exiting.`);
    process.exit(0);
  }
  console.error('[bridge] server error:', e);
  process.exit(1);
});

httpServer.listen(PORT, '127.0.0.1', () => {
  console.log(`[bridge] listening on ws://127.0.0.1:${PORT}`);
  console.log(`[bridge] health check http://127.0.0.1:${PORT}/health`);
  console.log(`[bridge] model ${cfg.llm?.model || '(unset)'} @ ${cfg.llm?.baseUrl || '(unset)'}`);
  if (!cfg.llm?.apiKey) {
    console.log('[bridge] note: llm.apiKey is empty in config.json; chat will be refused.');
  }
  if (!existsSync(BUNDLE)) {
    console.log(`[bridge] note: Perfect Pixel core bundle missing (${BUNDLE}).`);
    console.log('[bridge]       build it with: npm install && npm run build:pp');
  }
});
