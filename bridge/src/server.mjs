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
  };
}

// 写回 config.json：保留 systemPrompt 等其它字段，只更新 llm 段。
function saveConfig() {
  const raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
  raw.llm = { ...(raw.llm || {}), ...cfg.llm };
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
  }

  send(obj) {
    if (this.ws.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  say(kind, text) {
    this.send({ type: 'say', kind, text });
  }

  status(text) {
    this.send({ type: 'status', text });
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
      this.status('missing API key');
      return;
    }
    try {
      const dispatch = makeDispatcher({ session: this, bank, cfg, bundlePath: BUNDLE });
      await runTurn({
        cfg: cfg.llm,
        systemPrompt: SYSTEM_PROMPT,
        history: this.history,
        userText: text,
        context,
        tools: TOOLS,
        dispatch,
        onSay: (kind, t) => this.say(kind, t),
        onStatus: (t) => this.status(t),
      });
      // 只保留最近若干轮，避免上下文无限增长
      this.history = this.history.slice(-12);
    } catch (e) {
      this.say('error', `Error: ${e?.message || e}`);
      this.status('error');
    }
  }

  // 用当前配置做一次最小请求，验证 baseUrl / apiKey / model 是否可用
  async testLlm() {
    if (!cfg.llm?.apiKey) {
      this.say('error', 'Test failed: no API key set yet.');
      return;
    }
    const t0 = Date.now();
    this.status('testing LLM...');
    try {
      const r = await chatCompletion(cfg.llm, [
        { role: 'user', content: 'Reply with exactly: pong' },
      ], null);
      const text = String(r.choices?.[0]?.message?.content || '').trim().slice(0, 80);
      this.say('ai', `Connection OK in ${Date.now() - t0} ms -- model "${cfg.llm.model}" replied: ${text || '(empty)'}`);
    } catch (e) {
      this.say('error', `Connection failed: ${e?.message || e}`);
    }
    this.status('ready');
  }

  onText(msg) {
    switch (msg.type) {
      case 'hello': {
        this.info = msg;
        this.say('info', `Bridge ready. Aseprite ${msg.aseprite}, ${(msg.ops || []).length} ops available.`);
        this.status('ready');
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
      this.status('ready');
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
  session.status('connected, waiting for input');

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
