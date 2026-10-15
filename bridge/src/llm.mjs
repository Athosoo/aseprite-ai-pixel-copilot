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
  if (tools && tools.length) {
    body.tools = tools;
    body.tool_choice = 'auto';
  }

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), cfg.timeoutMs ?? 120000);

  // 外部信号 -> 内部 ctrl。已经 aborted 的要立刻生效（不能只等事件）。
  const onAbort = () => ctrl.abort();
  if (extraSignal) {
    if (extraSignal.aborted) ctrl.abort();
    else extraSignal.addEventListener('abort', onAbort, { once: true });
  }

  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${cfg.apiKey || ''}`,
      },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`LLM endpoint returned HTTP ${res.status}: ${text.slice(0, 600)}`);
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
  const { cfg, systemPrompt, history, userText, context, tools, dispatch, onSay, onStatus, abortSignal } = opts;

  // 系统提示每步重取：模型可能在**同一轮**里 style_use 换了风格，
  // 那后面的作画步骤就得立刻按新风格来（否则"换个风格画个图标"要两轮才生效）。
  // 没变的话内容一样，不多花 token。
  const sysNow = () => (typeof systemPrompt === 'function' ? systemPrompt() : systemPrompt);

  const messages = [{ role: 'system', content: sysNow() }, ...history];
  messages.push({ role: 'user', content: buildUserMessage(userText, context) });

  const maxSteps = cfg.maxSteps ?? 8;
  let finalText = '';

  // 中断检查点：每步开头、每次 HTTP 前后、每个工具调用前都要过一遍，
  // 否则"停止"要等到当前这一步跑完才生效。
  const reason = () => (abortSignal?.aborted ? (abortSignal.reason === 'timeout' ? 'timeout' : 'user') : null);
  const checkAbort = () => {
    const r = reason();
    if (r) throw new TurnAborted(r);
  };

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

    const msg = resp.choices?.[0]?.message;
    if (!msg) throw new Error('LLM response has no message field');

    // 去掉厂商特有字段，避免回传时被接口拒绝
    const clean = { role: 'assistant', content: msg.content ?? '' };
    if (msg.tool_calls && msg.tool_calls.length) clean.tool_calls = msg.tool_calls;
    messages.push(clean);

    // 推理模型的思考过程（DeepSeek reasoner 等）→ 灰色
    if (msg.reasoning_content && String(msg.reasoning_content).trim()) {
      const r = String(msg.reasoning_content).trim();
      onSay('think', r.length > 600 ? r.slice(0, 600) + ' …' : r);
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
  onSay('error', `Stopped: hit the ${maxSteps}-step tool limit. Try a smaller request.`);
  return finalText;
}
