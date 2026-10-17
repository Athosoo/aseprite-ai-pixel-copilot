// OpenAI 兼容接口客户端 + 工具调用循环
//
// 兼容 DeepSeek / 通义 / Kimi / 智谱 / 本地 Ollama 等任何 OpenAI 兼容端点：
// 只要 config.json 里填对 baseUrl + apiKey + model。

/**
 * 一轮对话被用户/超时中断时抛这个（和真正的错误区分开 —— 中断不是错误）。
 */
export class TurnAborted extends Error {
  constructor(reason = 'user') {
    super('turn aborted');
    this.name = 'TurnAborted';
    this.reason = reason;   // 'user' | 'timeout'
  }
}

/**
 * 单次 HTTP 请求自己超时（不是用户按了停止，也不是整轮超时）。
 * 单独一个类型是为了让 server 能给友好文案 + 告诉用户去哪儿调大，
 * 而不是把 fetch 那句 "This operation was aborted" 原样甩给用户。
 */
export class RequestTimeout extends Error {
  constructor(ms) {
    super(`LLM request timed out after ${Math.round(ms / 1000)}s`);
    this.name = 'RequestTimeout';
    this.timedOut = true;
    this.timeoutMs = ms;
  }
}

/**
 * @param extraSignal 外部的中断信号（面板上的「停止」/ Esc / 轮级超时）。
 *   它触发时我们 abort 掉内部的 ctrl，从而中断这次 fetch。
 */
export async function chatCompletion(cfg, messages, tools, extraSignal) {
  const url = String(cfg.baseUrl || '').replace(/\/+$/, '') + '/chat/completions';
  const body = {
    model: cfg.model,
    messages,
    temperature: cfg.temperature ?? 0.2,
    stream: false,
  };
  // 思考强度：只有用户显式选了（auto 以外的值）才发。很多兼容端点不认这个字段，
  // 认不出就 400 —— 下面 catch 到会去掉它重试一次，绝不因此连不上。
  const thinking = String(cfg.thinking || 'auto').toLowerCase();
  if (thinking === 'low' || thinking === 'medium' || thinking === 'high') {
    body.reasoning_effort = thinking;
  }
  if (tools && tools.length) {
    body.tools = tools;
    body.tool_choice = 'auto';
  }

  const ctrl = new AbortController();
  // 单次请求超时：默认 180s。推理模型 + 大提示词偶尔会超过 2 分钟，
  // 卡在这里的代价是"整轮白跑"，所以宁可放宽；面板设置里也能改（llm.timeoutMs）。
  const timeoutMs = Number(cfg.timeoutMs) > 0 ? Number(cfg.timeoutMs) : 180000;
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; ctrl.abort(); }, timeoutMs);

  // 外部信号 -> 内部 ctrl。已经 aborted 的要立刻生效（不能只等事件）。
  const onAbort = () => ctrl.abort();
  if (extraSignal) {
    if (extraSignal.aborted) ctrl.abort();
    else extraSignal.addEventListener('abort', onAbort, { once: true });
  }

  const post = async (payload) => {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${cfg.apiKey || ''}`,
        },
        body: JSON.stringify(payload),
        signal: ctrl.signal,
      });
      const text = await res.text();
      if (!res.ok) {
        const err = new Error(`LLM endpoint returned HTTP ${res.status}: ${text.slice(0, 600)}`);
        err.status = res.status;
        throw err;
      }
      return text;
    } catch (e) {
      // 只把"自己计时器踢的那一脚"翻译成超时；用户/整轮中断照旧往上抛
      // （runTurn 会把它转成 TurnAborted，那条路有自己的文案）。
      if (timedOut && !extraSignal?.aborted) throw new RequestTimeout(timeoutMs);
      throw e;
    }
  };

  let droppedThinking = false;
  try {
    let text;
    try {
      text = await post(body);
    } catch (e) {
      // 端点不认 reasoning_effort：去掉它重试一次，并把"已降级"标在返回值上
      if (body.reasoning_effort && (e.status === 400 || e.status === 422)) {
        delete body.reasoning_effort;
        text = await post(body);
        droppedThinking = true;
      } else {
        throw e;
      }
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error(`LLM did not return JSON: ${text.slice(0, 300)}`);
    }
    if (parsed.error) {
      throw new Error(`LLM error: ${parsed.error.message || JSON.stringify(parsed.error)}`);
    }
    if (droppedThinking) parsed.droppedThinking = true;
    return parsed;
  } finally {
    clearTimeout(timer);
    if (extraSignal) extraSignal.removeEventListener('abort', onAbort);
  }
}

function contextToText(ctx) {
  if (!ctx || !ctx.hasSprite) return 'No document is open.';
  const s = ctx.sprite;
  const lines = [];
  lines.push(`Sprite: ${s.name}  ${s.width}x${s.height}  colorMode=${s.colorMode}  frames=${s.frames}`);
  lines.push(`Layers (bottom to top): ${(s.layers || []).join(' / ')}`);
  lines.push(`Active layer: ${ctx.layer}  frame: ${ctx.frame}`);
  if (ctx.selection) {
    const r = ctx.selection;
    lines.push(`Selection: (${r.x},${r.y}) ${r.w}x${r.h}`);
  } else {
    lines.push('No selection.');
  }
  if (ctx.colors && ctx.colors.length) {
    const total = ctx.opaquePixels || 0;
    const parts = ctx.colors.map((c) => {
      const pct = total > 0 ? ((c.count / total) * 100).toFixed(1) : '0';
      return `${c.hex}(${c.count}px,${pct}%)`;
    });
    lines.push(`Colour usage (${total} opaque of ${ctx.totalPixels} pixels): ${parts.join(' ')}`);
  }
  lines.push(`Snapshots stored: ${ctx.versionCount || 0}`);
  return lines.join('\n');
}

// 保守的 reasoning 提取：只认 provider 明确给出的独立字段。
// 没有独立字段就返回空 —— 从 content 里"猜"哪里是思考会误伤正常回答，
// 而误伤正常回答比漏掉一段思考严重得多（任务书的硬要求：判定要保守）。
const REASONING_KEYS = ['reasoning_content', 'reasoning', 'thinking', 'reasoning_details'];

function reasoningText(value) {
  if (typeof value === 'string') return value.trim();
  // openrouter 系网关：reasoning_details: [{ type: 'reasoning.text', text }] 或 ['...']
  if (Array.isArray(value)) {
    return value
      .map((v) => (typeof v === 'string' ? v : (v && typeof v.text === 'string' ? v.text : '')))
      .filter(Boolean).join('\n').trim();
  }
  // 少数网关包成对象：{ text } / { content }
  if (value && typeof value === 'object') {
    for (const k of ['text', 'content']) {
      if (typeof value[k] === 'string' && value[k].trim()) return value[k].trim();
    }
  }
  return '';
}

export function pickReasoning(msg) {
  if (!msg || typeof msg !== 'object') return '';
  for (const key of REASONING_KEYS) {
    const text = reasoningText(msg[key]);
    if (text) return text;
  }
  return '';
}

export function buildUserMessage(userText, context) {
  return `[Current canvas state]\n${contextToText(context)}\n\n[User request]\n${userText}`;
}

/**
 * 跑一轮对话：调用 LLM，执行它请求的工具，直到给出最终文本。
 *
 * @param {object} opts
 *   cfg        config.json 的 llm 段
 *   systemPrompt  字符串，或 () => 字符串（每步重新取一次，见下）
 *   history    [{role,content}...] 之前的消息（会被就地追加）
 *   userText   用户这句话
 *   context    Lua 传来的画布状态
 *   tools      OpenAI 工具 schema 数组
 *   dispatch   async (name, args) => result
 *   onSay      (kind, text) => void
 *   onStatus   (text, kind) => void
 *   abortSignal 外部中断信号（见 chatCompletion）；中断时抛 TurnAborted
 */
export async function runTurn(opts) {
  const { cfg, systemPrompt, history, userText, context, tools, dispatch, onSay, onStatus, onThink, abortSignal, onHistory } = opts;

  // 系统提示每步重取：模型可能在**同一轮**里 style_use 换了风格，
  // 那后面的作画步骤就得立刻按新风格来（否则"换个风格画个图标"要两轮才生效）。
  // 没变的话内容一样，不多花 token。
  const sysNow = () => (typeof systemPrompt === 'function' ? systemPrompt() : systemPrompt);

  const messages = [{ role: 'system', content: sysNow() }, ...history];
  messages.push({ role: 'user', content: buildUserMessage(userText, context) });

  const maxSteps = Math.max(1, Number(cfg.maxSteps) || 24);
  let finalText = '';

  // 这一轮新产生的消息（不含系统提示）回写给调用方落盘。
  // 正常结束 / 撞步数上限 / 被中断，三条路都要回写：否则用户那句提问会凭空消失。
  let saidThinkingDrop = false;

  const flush = () => {
    if (!onHistory) return;
    try { onHistory(messages.slice(1)); } catch { /* 存不下来不影响这一轮 */ }
  };

  // 中断检查点：每步开头、每次 HTTP 前后、每个工具调用前都要过一遍，
  // 否则"停止"要等到当前这一步跑完才生效。
  const reason = () => (abortSignal?.aborted ? (abortSignal.reason === 'timeout' ? 'timeout' : 'user') : null);
  const checkAbort = () => {
    const r = reason();
    if (r) throw new TurnAborted(r);
  };

  try {
    for (let step = 0; step < maxSteps; step++) {
      checkAbort();
      messages[0] = { role: 'system', content: sysNow() };
      onStatus(step === 0 ? 'thinking...' : `working (step ${step + 1})...`, 'busy');

      let resp;
      try {
        resp = await chatCompletion(cfg, messages, tools, abortSignal);
      } catch (e) {
        // fetch 被 abort 时抛 AbortError —— 转成 TurnAborted，别当错误报给用户
        if (abortSignal?.aborted) throw new TurnAborted(reason() || 'user');
        throw e;
      }
      checkAbort();

      if (resp.droppedThinking && !saidThinkingDrop) {
        saidThinkingDrop = true;
        onSay('warn', 'This endpoint does not accept a thinking-effort setting; it is being ignored.', 'thinkingDropped');
      }

      const msg = resp.choices?.[0]?.message;
      if (!msg) throw new Error('LLM response has no message field');

      // 去掉厂商特有字段，避免回传时被接口拒绝
      const clean = { role: 'assistant', content: msg.content ?? '' };
      if (msg.tool_calls && msg.tool_calls.length) clean.tool_calls = msg.tool_calls;
      messages.push(clean);

      // 推理模型的思考过程（DeepSeek reasoner 等）单独走 thinking 通道。
      // 它绝不能走 say —— 面板把 say 当正文渲染，用户看到一大段英文思考会以为 AI 在胡说。
      const reasoning = pickReasoning(msg);
      if (reasoning) {
        const clipped = reasoning.length > 600 ? reasoning.slice(0, 600) + ' …' : reasoning;
        if (onThink) onThink(clipped);
        else onSay('think', clipped);   // 没有 thinking 通道的调用方（旧脚本/嵌入式）保持原样
      }

      if (msg.content && msg.content.trim()) {
        const text = msg.content.trim();
        const hasTools = !!(msg.tool_calls && msg.tool_calls.length);
        // 带工具调用的那段话是"中间叙述/思考"，最终回答才是输出
        onSay(hasTools ? 'think' : 'ai', text);
        if (!hasTools) finalText = text;
      }

      if (!msg.tool_calls || msg.tool_calls.length === 0) {
        onStatus('ready', 'ok');
        return finalText;
      }

      for (const call of msg.tool_calls) {
        checkAbort();
        const name = call.function?.name;
        let args = {};
        try {
          args = JSON.parse(call.function?.arguments || '{}');
        } catch (e) {
          args = { __parseError: String(e.message || e) };
        }
        onStatus(`running ${name}...`, 'tool');
        let result;
        try {
          result = await dispatch(name, args);
        } catch (e) {
          result = { error: String(e?.message || e) };
        }
        checkAbort();
        messages.push({
          role: 'tool',
          tool_call_id: call.id,
          content: JSON.stringify(result).slice(0, 8000),
        });
      }
    }

    onStatus('ready', 'ok');
    onSay('warn', `Stopped at this turn's limit of ${maxSteps} steps. Say "continue" and I will carry on from here.`, 'stepLimit');
    return finalText;
  } finally {
    flush();
  }
}
