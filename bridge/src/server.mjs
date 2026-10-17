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
import { MODEL_TOOLS, makeDispatcher, registry, evolution, journal, PACK_DIRS } from './tools.mjs';
import { loadPacks } from './packs.mjs';
import { runTurn, chatCompletion } from './llm.mjs';
import { clampBudget } from './history.mjs';
import { ConversationStore } from './conversations.mjs';
import { GapLog } from './gaps.mjs';

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

// 对话：一个对话一个文件（data/conversations/<id>.json），超长自动压缩。
// 老的 data/history.json 会被 store 自动迁成第一个对话（原文件留底）。
//   * `history` 是**稳定引用**：切对话时 store 换的是它的 file 再 load，
//     所以下面所有 `history.xxx` 调用都不用关心"现在是哪个对话"。
//   * 消息 + 摘要 + 留档 + 面板回放行，全在同一个文件里（见 history.mjs）。
const store = new ConversationStore({
  dir: join(ROOT, cfg.paths?.conversations || 'data/conversations'),
  budgetTokens: cfg.llm?.contextTokens,
  legacyFile: join(ROOT, cfg.paths?.history || 'data/history.json'),
  activeId: cfg.activeConversation || '',
});
const history = store.current;

// "当前是哪个对话"落盘（和 activeStyle 一个套路），重启桥还认
function persistActiveConversation(id) {
  cfg.activeConversation = id;
  try {
    const raw = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
    raw.activeConversation = id;
    writeFileSync(CONFIG_PATH, JSON.stringify(raw, null, 2), 'utf8');
  } catch { /* 存不下来不影响本次会话 */ }
}

// 第一次跑（或上次那个被删了）时 store 会自动建/挑一个，这里把它记下来 ——
// 不记的话下次重启就只能靠"最近更新过的那个"猜。
if (cfg.activeConversation !== store.activeId) persistActiveConversation(store.activeId);

// 做不到的需求：模型（或自动兜底）记进 data/gaps.md，开发者读它去实现。
const gaps = new GapLog({ file: join(ROOT, cfg.paths?.gaps || 'data/gaps.md') });

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
// 数值配置统一在这里夹：面板可能发来空串 / 越界值 / NaN
function clampNum(v, lo, hi, fallback) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(hi, Math.max(lo, n));
}

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
      maxSteps: cfg.llm?.maxSteps ?? 24,
      contextTokens: history.budgetTokens,
      temperature: cfg.llm?.temperature ?? 0.2,
      thinking: cfg.llm?.thinking || 'auto',
      // 超时（毫秒）：单次 HTTP 请求 / 整轮对话。面板设置里按秒显示、改完立刻生效。
      timeoutMs: cfg.llm?.timeoutMs ?? 180000,
      maxTurnMs: cfg.llm?.maxTurnMs ?? 600000,
    },
    port: PORT,
    colorBank: BANK_PATH,
    perfectPixelReady: existsSync(BUNDLE),
    workspace: { root: cfg.workspace?.root || '' },
    conversation: {
      id: store.activeId,
      title: history.title,
      count: store.stats().count,
    },
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
    this.busy = false;
    this.queue = [];
    this.info = {};
    this.turnAbort = null;     // 当前这一轮的中断控制器（P3）
    this.turnProcessed = new Set();  // 本轮已经处理过的图片来源（P8 防复读）
  }

  send(obj) {
    if (this.ws.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  // i18nKey 有值时，面板会用本地化文案覆盖 text（P3 的中断提示等）；
  // i18nArgs 是 %d/%s 的实参（"超时 180 秒"里的 180）。
  // record=false 的行不进对话回放（握手提示这种连接噪声不该污染记录）
  say(kind, text, i18nKey, record = true, i18nArgs = null) {
    if (record) history.pushLog(kind, text, i18nKey, i18nArgs);
    const msg = { type: 'say', kind, text, i18n: i18nKey };
    if (i18nArgs) msg.i18nArgs = i18nArgs;
    this.send(msg);
  }

  // 把当前对话的记录推给面板（面板收到就清屏重画）——关掉面板 / 重启 Aseprite 之后
  // "它还记得我们聊过"靠的就是这条。桥是唯一真相来源，所以是替换不是追加。
  sendReplay() {
    const r = store.replay(400);
    this.send({
      type: 'replay',
      id: store.activeId,
      title: history.title,
      count: store.stats().count,
      lines: r.lines,
      more: r.more,
    });
  }

  // 切/建/删对话之后的统一收尾：落盘活动对话 + 刷新电量条 + 回放新对话
  afterConversationChange() {
    persistActiveConversation(store.activeId);
    this.pushContext();
    this.sendReplay();
  }

  status(text, kind) {
    this.send({ type: 'status', text, kind });
    this.pushContext();
  }

  // 上下文用量 -> 面板的 20 格电量条。每步一次，消息条数很少，算得起。
  pushContext() {
    this.send({
      type: 'context',
      used: history.usedTokens(),
      budget: history.budgetTokens,
      messages: history.messages.length,
      summaryChars: history.summary.length,
    });
  }

  request(kind, payload = {}, timeoutMs = 60000) {
    return this.requestSend(kind, payload, timeoutMs).promise;
  }

  // request 的"只登记、先别结束"版本：给需要【先发头帧、再发二进制负载】的调用用。
  // 直接 await request(...) 再发负载会死锁 —— 扩展侧要等二进制帧配对才会回话。
  requestSend(kind, payload = {}, timeoutMs = 60000) {
    const id = ++this.seq;
    let send;
    const promise = new Promise((resolve, reject) => {
      send = () => this.send({ type: kind, id, ...payload });
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`等待 Aseprite 响应超时：${kind}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (v) => { clearTimeout(timer); resolve(v); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      });
    });
    send();
    return { id, promise };
  }

  resolvePending(id, value) {
    const p = this.pending.get(id);
    if (p) {
      this.pending.delete(id);
      p.resolve(value);
    }
  }

  // 头帧 + 二进制负载成对发出（ws.lua 认 binary=true 的头帧，收下等二进制帧配对）。
  // 别去掉 binary 标记：去掉的话 Lua 会把它当普通消息，二进制帧配不上头就丢了。
  sendBinary(header, data) {
    this.send(header);
    this.ws.send(Buffer.from(data.buffer, data.byteOffset, data.byteLength), { binary: true });
  }

  // 把矫正结果送进 Aseprite，并【等它回话】这个结果到底怎么落地的。
  //
  // 以前这里是 fire-and-forget：只发头帧 + 二进制帧，没人回，于是桥只能对模型
  // 说"开了一个新文档"—— 哪怕扩展侧其实是就地贴图层 / 因为没有文档而退回预览。
  // 现在 import_image 走 request（同一个 id 头帧 + 二进制负载），扩展侧落完地
  // 回 {type:'import_result', id}，桥据此如实回报。
  //
  // opts.target: 'active'（就地贴进当前文档的新图层）/ 'preview'（开预览文档 + 留待应用）
  // opts.label:  落地时给模型看的来源名（"fixed image" / 上传文件名）
  async sendImport(data, width, height, note, opts = {}) {
    const payload = {
      type: 'import_image',
      width,
      height,
      note,
      binary: true,          // 告诉 Lua 侧"后面还跟着一个二进制帧"，它据此把头帧存起来等配对。
      target: opts.target || 'preview',
      label: opts.label || 'fixed image',
    };
    try {
      // 20s：落地要 push 快照（可能落盘）+ 一个事务，比普通算子重，但远不到 60s
      // 顺序很重要：头帧 -> 二进制负载 -> 等结果。反了就是死锁（Lua 等负载才回话）。
      const { promise } = this.requestSend('import_image', payload, 20000);
      this.ws.send(Buffer.from(data.buffer, data.byteOffset, data.byteLength), { binary: true });
      const res = await promise;
      return res || { applied: false, pending: true };
    } catch (err) {
      return { applied: false, pending: false, error: err && err.message ? err.message : String(err) };
    }
  }

  // 收到一个用户指令，串行处理（同一时间只跑一轮对话）
  enqueueChat(text, context) {
    // gaps 记录要用：这一轮用户说的原话
    this.lastUserText = String(text || '').slice(0, 300);
    // 面板回放要看到"我说过什么"，所以用户这句也记一行
    history.pushLog('user', text);
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
    // 每轮重新给 3 次 propose 预算（arch §6 预算护栏是「单轮会话」粒度）
    evolution.resetTurn();

    const ac = new AbortController();
    this.turnAbort = ac;
    this.turnProcessed = new Set();
    // 整轮上限默认 10 分钟：一轮里最多 24 步、每步一次 HTTP，180s 那种量级
    // 连"多步慢慢画"的正常活都跑不完（用户反馈"超时太严格"多半是这条）。
    const maxTurnMs = Number(cfg.llm?.maxTurnMs) > 0 ? Number(cfg.llm.maxTurnMs) : 600000;
    const turnTimer = setTimeout(() => ac.abort('timeout'), maxTurnMs);

    try {
      const dispatch = makeDispatcher({
        session: this, bank, memory, styles, cfg, bundlePath: BUNDLE, gaps,
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
        let out = styleText ? `${SYSTEM_PROMPT}\n\n${styleText}` : SYSTEM_PROMPT;
        // 被压缩掉的旧对话摘要常驻在这里（systemPrompt 是函数，每步重取，压缩完立刻生效）
        const block = history.summaryBlock();
        if (block) out += `\n\n${block}`;
        return out;
      };
      // 压缩：超长时先把最老的一段摘要掉，再拼消息。
      // 放在 runTurn 之前，这样本轮一开始看到的就是压缩后的上下文。
      if (history.needsCompaction()) {
        const rep = await this.compactHistory();
        if (rep.compacted) {
          this.say('info',
            `Context compacted: ${rep.dropped} older messages summarised (${rep.tokensBefore} -> ${history.usedTokens()} tokens).`,
            'ctxCompacted');
        }
      }

      await runTurn({
        cfg: cfg.llm,
        systemPrompt: buildSystemPrompt,
        history: history.messages,          // runTurn 会就地追加（同一个数组引用）
        userText: text,
        context,
        tools: MODEL_TOOLS,
        dispatch,
        abortSignal: ac.signal,
        onSay: (kind, t, key) => this.say(kind, t, key),
        onStatus: (t, kind) => this.status(t, kind),
        // 这一轮新产生的消息（含被打断的半截）回写进历史
        onHistory: (msgs) => { history.messages = msgs; },
      });
      // 落盘：重启桥 / 重启 Aseprite 之后还接得上
      history.save();
      this.pushContext();          // 压缩过的话电量条要立刻掉下来
    } catch (e) {
      if (e?.name === 'TurnAborted') {
        // 中断不是错误：手动和超时给不同的提示
        if (e.reason === 'timeout') {
          this.say('info',
            `The whole turn took longer than ${Math.round(maxTurnMs / 1000)}s, so it was interrupted.`,
            'abortTimeout', true, [Math.round(maxTurnMs / 1000)]);
        } else {
          this.say('info', 'Task interrupted.', 'aborted');
        }
      } else if (e?.timedOut) {
        // 单次请求超时：说清是多少秒、去哪儿调大 —— 别把 AbortError 甩给用户
        const secs = Math.round((e.timeoutMs || 0) / 1000);
        this.say('warn',
          `The model did not answer within ${secs}s, so the request was dropped.`,
          'llmTimeout', true, [secs]);
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

  // 把最老的一段历史交给 LLM 摘要（上下文压缩）。失败不影响本轮对话。
  async compactHistory() {
    const rep = await history.compact(async (text) => {
      const resp = await chatCompletion(cfg.llm, [
        {
          role: 'system',
          content:
            'You compress earlier parts of a conversation between a user and a pixel-art assistant. ' +
            'Keep: decisions made, file/layer/colour names, sizes, what was drawn or edited, what is still ' +
            'pending, and anything the user asked to remember. Drop tool chatter and pleasantries. ' +
            'Write at most 120 words, in the same language the conversation used. Plain text, no headings.',
        },
        { role: 'user', content: text },
      ], null);
      return resp.choices?.[0]?.message?.content || '';
    });
    return rep;
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

  async onText(msg) {
    switch (msg.type) {
      case 'hello': {
        this.info = msg;
        // 先回放上次的记录（面板收到就清屏重画），再发握手提示 —— 反过来的话
        // 提示会被回放冲掉，用户看到的第一屏就少了那几行。
        this.sendReplay();
        // 下面这些都是连接噪声：只给面板看，不进对话记录
        this.say('info', `Bridge ready. Aseprite ${msg.aseprite}, ${(msg.ops || []).length} ops available.`, null, false);
        this.status('ready', 'ok');
        this.send(configPayload());
        if (!cfg.llm?.apiKey) {
          this.say('info', 'No API key yet -- click Settings in the panel to paste one.', null, false);
        }
        this.pushContext();
        const gs = gaps.stats();
        if (gs.entries > 0) {
          this.say('info', `Known gaps on file: ${gs.entries} (see ${gs.file}).`, 'gapsKnown', false);
        }
        const cs = store.stats();
        this.say('info', `Conversation "${cs.title || 'untitled'}" -- ${cs.count} on file. Type "chats" to switch.`, 'convActive', false);
        const st = history.stats();
        if (st.messages > 0) {
          this.say('info', `Context restored: ${st.messages} message(s), about ${st.tokens} tokens` +
            (st.summaryChars ? `, plus a ${st.summaryChars}-char summary` : '') +
            (st.archived ? `, ${st.archived} archived` : '') +
            '.', 'ctxRestored', false);
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
        // 高级项：步数 / 上下文预算 / 温度 / 思考强度（都在设置面板里调）
        if (llm.maxSteps !== undefined) cfg.llm.maxSteps = clampNum(llm.maxSteps, 1, 200, 24);
        if (llm.temperature !== undefined) cfg.llm.temperature = clampNum(llm.temperature, 0, 2, 0.2);
        // 超时（毫秒）。下限 10s：比这更短的话正常一轮都跑不完，纯属自找麻烦；
        // 上限 30min/60min：够慢的推理模型用，再长就该去查网络了。
        if (llm.timeoutMs !== undefined) cfg.llm.timeoutMs = clampNum(llm.timeoutMs, 10000, 1800000, 180000);
        if (llm.maxTurnMs !== undefined) cfg.llm.maxTurnMs = clampNum(llm.maxTurnMs, 30000, 3600000, 600000);
        if (typeof llm.thinking === 'string' && ['auto', 'low', 'medium', 'high'].includes(llm.thinking)) {
          cfg.llm.thinking = llm.thinking;
        }
        if (llm.contextTokens !== undefined) {
          cfg.llm.contextTokens = clampBudget(llm.contextTokens);
          history.budgetTokens = cfg.llm.contextTokens;   // 立刻生效，不用重启桥
          this.pushContext();
        }
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
          this.say('info', 'Settings saved to bridge/config.json (effective immediately).', 'setSaved');
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
      case 'import_result':
        // perfect_pixel 结果的落地回执：就地加层 / 开预览文档 / 扩了画布，都由这里说清楚
        this.resolvePending(msg.id, msg.applied
          ? {
              applied: true,
              layer: msg.layer, canvas: msg.canvas, canvasFrom: msg.canvasFrom,
              expanded: msg.expanded === true, pending: msg.pending === true,
            }
          : {
              applied: false, openedDoc: msg.openedDoc === true,
              pending: msg.pending === true, reason: msg.reason, error: msg.error,
            });
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
      case 'reset_history': {
        const rep = history.reset();
        this.historyReset = true;
        this.pushContext();
        this.say('info', 'This conversation is now empty. Use "new chat" if you want to keep it and start another.', 'ctxCleared');
        this.send({ type: 'history_result', id: msg.id, reset: true, ...rep });
        break;
      }
      case 'gaps_info': {
        const gs = gaps.stats();
        this.send({ type: 'gaps_result', id: msg.id, ...gs, recent: gaps.recent(3) });
        break;
      }
      case 'history_info':
        this.send({ type: 'history_result', id: msg.id, ...history.stats(), summary: history.summary });
        break;

      // ---- 多对话（v0.5.8）。注意 msg.id 是【请求 id】，对话 id 走 msg.target，
      //      两个都是 id 太容易串，所以回复里对话 id 一律叫 convId。
      case 'conversation_list':
        this.send({
          type: 'conversations_result',
          id: msg.id,
          items: store.list(),
          active: store.activeId,
          title: history.title,
          dir: store.dir,
        });
        break;
      case 'conversation_new': {
        const rep = store.create({ title: msg.title || '' });
        this.say('info', `New conversation started (#${store.stats().count}).`, 'convNew');
        this.afterConversationChange();
        this.send({
          type: 'conversation_result', id: msg.id, ok: true, action: 'new',
          convId: rep.id, active: store.activeId, title: history.title, count: store.stats().count,
        });
        break;
      }
      case 'conversation_switch': {
        const rep = store.activate(msg.target ?? msg.index ?? msg.convId);
        if (!rep.ok) {
          this.say('error', `No such conversation: ${msg.target ?? msg.index ?? ''}`, 'convNotFound');
        } else {
          this.say('info', `Switched to "${rep.title || history.title || 'untitled'}".`, 'convSwitched');
          this.afterConversationChange();
        }
        this.send({
          type: 'conversation_result', id: msg.id, ok: rep.ok, action: 'switch',
          convId: rep.id || store.activeId, active: store.activeId, title: history.title,
          reason: rep.reason, unchanged: rep.unchanged,
          count: store.stats().count,
        });
        break;
      }
      case 'conversation_rename': {
        const rep = store.rename(msg.target ?? msg.convId ?? store.activeId, msg.title);
        if (rep.ok) this.say('info', `Renamed to "${rep.title}".`, 'convRenamed');
        else this.say('error', rep.reason === 'empty-title' ? 'A name is required.' : 'No such conversation.', 'convRenameFailed');
        this.send({
          type: 'conversation_result', id: msg.id, ok: rep.ok, action: 'rename',
          convId: rep.id || store.activeId, active: store.activeId, title: rep.title, reason: rep.reason,
          count: store.stats().count,
        });
        break;
      }
      case 'conversation_delete': {
        const rep = store.remove(msg.target ?? msg.convId ?? store.activeId);
        if (rep.ok) {
          this.say('info', `Deleted "${rep.title}" (moved to trash). Now on "${history.title || 'untitled'}".`, 'convDeleted');
          this.afterConversationChange();
        } else if (rep.reason === 'last') {
          this.say('warn', 'That is the only conversation left -- use "clear" to empty it instead.', 'convLast');
        } else {
          this.say('error', 'No such conversation.', 'convNotFound');
        }
        this.send({
          type: 'conversation_result', id: msg.id, ok: rep.ok, action: 'delete',
          convId: rep.id || store.activeId, active: store.activeId, title: rep.title, reason: rep.reason,
          next: rep.next, count: store.stats().count,
        });
        break;
      }
      case 'history_replay':
        this.sendReplay();
        break;
      // 面板本地产的那几行（切形态、设置保存…）也记一笔，回放时才和现场一致。
      // 只记账，不回声 —— 面板自己已经画过了。
      case 'log':
        history.pushLog(msg.kind || 'info', msg.text);
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
      // ---- 能力清单 / 自扩展（arch §5.4：旧 type 一个不动，这里只加新的）----
      case 'cap.list': {
        // 能力清单不进常驻 prompt（D5），模型/面板按 query 来查
        const q = String(msg.query || '').trim().toLowerCase();
        const limit = Number.isInteger(msg.limit) && msg.limit > 0 ? Math.min(msg.limit, 200) : 60;
        const all = registry.list().filter((s) => s.expose !== false).map((s) => ({
          name: s.name,
          pack: s.pack,
          evolved: !!s.meta?.evolved,
          description: String(s.description || '').split(/(?<=[.。])\s/)[0],
        }));
        const caps = q ? all.filter((c) => (c.name + ' ' + c.pack + ' ' + c.description).toLowerCase().includes(q)) : all;
        this.send({ type: 'cap.result', id: msg.id, ok: true, query: q, total: all.length, caps: caps.slice(0, limit) });
        break;
      }

      // packId 是包 id（msg.id 是请求关联号，两者不能混用）
      case 'pack.propose': {
        const rep = evolution.propose({ id: String(msg.packId || ''), files: msg.files, rationale: msg.rationale });
        // id 一定要放最后：rep 里的 pack id 会覆盖关联号（踩过一次）
        this.send({ type: 'pack.propose_result', ok: !rep.error, ...rep, id: msg.id });
        break;
      }

      case 'pack.verify': {
        const rep = await evolution.verify({ staged: String(msg.staged || '') });
        this.send({ type: 'pack.verify_result', ...rep, id: msg.id });
        break;
      }

      case 'pack.activate': {
        const rep = await evolution.activate({ staged: String(msg.staged || '') });
        this.send({ type: 'pack.activate_result', ok: !rep.error, packId: rep.id, ...rep, id: msg.id });
        break;
      }

      case 'pack.rollback': {
        const rep = await evolution.rollback({ id: String(msg.packId || '') });
        this.send({ type: 'pack.rollback_result', packId: msg.packId, ...rep, id: msg.id });
        break;
      }

      case 'view.invalidate': {
        // 双向帧：Lua 侧报脏，桥广播给其它在线端；桥自己发的时候带 view 名
        for (const s of sessions) {
          if (s === this) continue;
          s.send({ type: 'view.invalidate', view: msg.view, rect: msg.rect });
        }
        break;
      }

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

// ---------------------------------------------------------------- 能力包
// 用户包（模型写的那一层）启动时装一次；之后每次 activate/rollback 由 evolution
// 自己重载 —— 不重启桥就能换实现，这是「模型能修改自己」的前提。
const bootPacks = await loadPacks({ dirs: [PACK_DIRS.user], registry, journal: journal.log });
if (bootPacks.loaded.length) console.log('[bridge] packs loaded: ' + bootPacks.loaded.map((p) => p.id).join(', '));
for (const e of bootPacks.errors) console.log('[bridge] pack failed: ' + e.id + ' -- ' + e.err);

// pack.changed 推给每个在线面板：Lua 侧收到就热装载，UI 的「扩展」页据此标红/标绿。
// 顺带发一条 view.invalidate，让面板只重画「扩展」那一块（arch §6 脏区重绘）。
evolution.setChangedHandler(({ id, action }) => {
  for (const s of sessions) {
    s.send({ type: 'pack.changed', id, action });
    s.send({ type: 'view.invalidate', view: 'packs' });
  }
});

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
    session.onText(msg).catch((e) => console.log('[bridge] handler error:', e?.message || e));
  });

  ws.on('close', () => {
    sessions.delete(session);
    // 关面板/关 Aseprite：把最后一轮之后产生的行（工具提示、错误…）也落盘
    try { history.save(); } catch { /* 存不下来不影响退出 */ }
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
  console.log(`[bridge] conversation ${store.activeId} "${history.title || '(untitled)'}" (${store.stats().count} on file, ${history.messages.length} messages)`);
  if (!cfg.llm?.apiKey) {
    console.log('[bridge] note: llm.apiKey is empty in config.json; chat will be refused.');
  }
  if (!existsSync(BUNDLE)) {
    console.log(`[bridge] note: Perfect Pixel core bundle missing (${BUNDLE}).`);
    console.log('[bridge]       build it with: npm install && npm run build:pp');
  }
});
