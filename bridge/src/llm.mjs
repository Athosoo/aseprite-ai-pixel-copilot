// OpenAI 兼容接口客户端 + 工具调用循环
//
// 兼容 DeepSeek / 通义 / Kimi / 智谱 / 本地 Ollama 等任何 OpenAI 兼容端点：
// 只要 config.json 里填对 baseUrl + apiKey + model。

export async function chatCompletion(cfg, messages, tools) {
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
 *   systemPrompt
 *   history    [{role,content}...] 之前的消息（会被就地追加）
 *   userText   用户这句话
 *   context    Lua 传来的画布状态
 *   tools      OpenAI 工具 schema 数组
 *   dispatch   async (name, args) => result
 *   onSay      (kind, text) => void
 *   onStatus   (text) => void
 */
export async function runTurn(opts) {
  const { cfg, systemPrompt, history, userText, context, tools, dispatch, onSay, onStatus } = opts;

  const messages = [{ role: 'system', content: systemPrompt }, ...history];
  messages.push({ role: 'user', content: buildUserMessage(userText, context) });

  const maxSteps = cfg.maxSteps ?? 8;
  let finalText = '';

  for (let step = 0; step < maxSteps; step++) {
    onStatus(step === 0 ? 'thinking...' : `working (step ${step + 1})...`);
    const resp = await chatCompletion(cfg, messages, tools);
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
      onStatus('ready');
      return finalText;
    }

    for (const call of msg.tool_calls) {
      const name = call.function?.name;
      let args = {};
      try {
        args = JSON.parse(call.function?.arguments || '{}');
      } catch (e) {
        args = { __parseError: String(e.message || e) };
      }
      onStatus(`running ${name}...`);
      let result;
      try {
        result = await dispatch(name, args);
      } catch (e) {
        result = { error: String(e?.message || e) };
      }
      messages.push({
        role: 'tool',
        tool_call_id: call.id,
        content: JSON.stringify(result).slice(0, 8000),
      });
    }
  }

  onStatus('ready');
  onSay('error', `Stopped: hit the ${maxSteps}-step tool limit. Try a smaller request.`);
  return finalText;
}
