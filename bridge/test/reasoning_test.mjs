// reasoning 分流测试：模型的思考过程绝不能被当成正文发出去。
//
//   cd bridge && node test/reasoning_test.mjs
//
// 真机症状：会话区出现 "The user says '新建' ... Rule 8 says when ambiguous ask." 这种英文思考，
// 用户以为 AI 在胡说。根因是 reasoning 走了 say 通道（面板把 say 当正文渲染）。
// 这里用两份假响应做对照：带独立 reasoning 字段 / 不带。判定必须保守 —— 没有独立字段时不许拆。

import { pickReasoning, runTurn } from '../src/llm.mjs';

let pass = 0, fail = 0;
const ok = (cond, name, extra) => {
  if (cond) { pass++; console.log('  ok   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra !== undefined ? '  <- ' + JSON.stringify(extra) : '')); }
};

// 假 fetch：把 chatCompletion 的 HTTP 层整个替掉，不碰网络
function installFetch(responder) {
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    globalThis.__lastReq = body;
    const payload = responder(body);
    const okRes = !payload.__status;
    return {
      ok: okRes,
      status: payload.__status || 200,
      text: async () => JSON.stringify(payload.body || payload),
      json: async () => (okRes ? payload : payload.body),
    };
  };
}

const CFG = { baseUrl: 'http://fake.local/v1', apiKey: 'k', model: 'm', temperature: 0, maxSteps: 4, timeoutMs: 5000 };
const THOUGHT = "The user says '新建'. I should ask size? Rule 8 says when ambiguous ask.";
const ANSWER = '多大的画布？比如 32x32。';

// 跑一轮，把三类回调分开收集（say / think / status）
async function turn(responder, opts = {}) {
  installFetch(responder);
  const says = [];
  const thinks = [];
  const statuses = [];
  const history = [];
  let pushed = [];
  const finalText = await runTurn({
    cfg: CFG,
    systemPrompt: '你是像素画助手。',
    history,
    userText: '新建',
    context: { sprite: null },
    tools: [],
    dispatch: async (name) => ({ ok: true, name }),
    onSay: (kind, text) => says.push({ kind, text }),
    onThink: opts.noThink ? undefined : (text) => thinks.push(text),
    onStatus: (text, kind) => statuses.push({ text, kind }),
    abortSignal: new AbortController().signal,
    onHistory: (msgs) => { pushed = msgs; },
  });
  // 回传给下一轮的历史（不含 system）—— 厂商特有字段绝不能出现在这里
  return { finalText, says, thinks, statuses, history, sent: pushed };
}

const reply = (message) => () => ({ id: 'x', choices: [{ index: 0, message, finish_reason: 'stop' }] });

console.log('== 带独立 reasoning_content（deepseek reasoner 风格）==');
{
  const r = await turn(reply({ role: 'assistant', reasoning_content: THOUGHT, content: ANSWER }));
  ok(r.thinks.length === 1, '思考进了 thinking 通道，实际 ' + r.thinks.length + ' 条');
  ok(!!(r.thinks[0] || '').includes('Rule 8'), 'thinking 通道里就是那段思考原文，实际 ' + JSON.stringify(r.thinks));
  const sayKinds = r.says.map((s) => s.kind);
  ok(!sayKinds.includes('think'), 'say 通道里没有 think 类帧，实际 ' + JSON.stringify(sayKinds));
  ok(!r.says.some((s) => String(s.text || '').includes('Rule 8')), '思考原文没有出现在任何 say 里');
  const ai = r.says.filter((s) => s.kind === 'ai');
  ok(ai.length === 1 && ai[0].text === ANSWER, '正文照常发 ai 帧，实际 ' + JSON.stringify(ai));
  ok(r.finalText === ANSWER, '最终回答只取正文，实际 ' + JSON.stringify(r.finalText));

  const assistant = r.sent.filter((m) => m.role === 'assistant');
  ok(assistant.length === 1 && assistant[0].reasoning_content === undefined && assistant[0].reasoning_details === undefined,
    '回传历史里不带 reasoning 字段（厂商特有字段回传会被拒），实际 ' + JSON.stringify(assistant));
}

console.log('== 等价字段：reasoning_details 数组（openrouter 系网关）==');
{
  const r = await turn(reply({
    role: 'assistant',
    reasoning_details: [{ type: 'reasoning.text', text: THOUGHT }],
    content: ANSWER,
  }));
  ok(r.thinks.length === 1 && (r.thinks[0] || '').includes('Rule 8'), 'reasoning_details 也被认出来，实际 ' + JSON.stringify(r.thinks));
  ok(!r.says.some((s) => String(s.text || '').includes('Rule 8')), '同样没有漏进 say');
  ok(r.finalText === ANSWER, '正文不受影响');
}

console.log('== 对照：没有 reasoning 字段（正常回答不许被误伤）==');
{
  const r = await turn(reply({ role: 'assistant', content: ANSWER }));
  ok(r.thinks.length === 0, '没有独立 reasoning 字段时一条 thinking 都不发，实际 ' + r.thinks.length);
  const ai = r.says.filter((s) => s.kind === 'ai');
  ok(ai.length === 1 && ai[0].text === ANSWER, '正文照常一条 ai 帧');
  ok(r.finalText === ANSWER, '最终回答不变');
}

console.log('== 保守判定：思考看起来像思考、但没有独立字段 => 不许拆 ==');
{
  // 这正是"误伤"的场景：正文里出现了 Rule 8 / I should ask 这种措辞，
  // 但它就是 content，不是 provider 声明的 reasoning —— 一个字都不许动。
  const r = await turn(reply({ role: 'assistant', content: THOUGHT + '\n' + ANSWER }));
  ok(r.thinks.length === 0, '没有独立字段就不分流，实际 ' + r.thinks.length + ' 条 thinking');
  const ai = r.says.filter((s) => s.kind === 'ai');
  ok(ai.length === 1 && ai[0].text.includes('Rule 8'), 'content 原样当正文发出去（不猜、不截断）');
  ok(r.finalText.includes('Rule 8'), '最终回答里也原样保留');
}

console.log('== 带工具调用的一步：思考照旧走 thinking，正文是中间叙述 ==');
{
  let step = 0;
  const r = await turn(() => {
    step++;
    if (step === 1) {
      return {
        id: 'x',
        choices: [{
          index: 0,
          message: {
            role: 'assistant',
            reasoning_content: THOUGHT,
            content: '先看看画布。',
            tool_calls: [{ id: 'c1', type: 'function', function: { name: 'canvas_info', arguments: '{}' } }],
          },
        }],
      };
    }
    return { id: 'x', choices: [{ index: 0, message: { role: 'assistant', content: ANSWER } }] };
  });
  ok(r.thinks.length === 1, '第一步的 reasoning 进 thinking，实际 ' + r.thinks.length);
  ok(!r.says.some((s) => String(s.text || '').includes('Rule 8')), 'reasoning 没进 say');
  const thinkSays = r.says.filter((s) => s.kind === 'think');
  ok(thinkSays.length === 1 && thinkSays[0].text === '先看看画布。', '带工具调用的中间叙述仍走 think 类（弱化），实际 ' + JSON.stringify(thinkSays));
  ok(r.says.filter((s) => s.kind === 'ai').length === 1, '只有最后那句正文是 ai 帧');
  ok(r.finalText === ANSWER, '最终回答是第二步的正文');
}

console.log('== 兼容：调用方没有 thinking 通道时退回旧的 think 类 ==');
{
  const r = await turn(reply({ role: 'assistant', reasoning_content: THOUGHT, content: ANSWER }), { noThink: true });
  ok(r.thinks.length === 0, '没传 onThink 就没有 thinking 回调');
  const thinkSays = r.says.filter((s) => s.kind === 'think');
  ok(thinkSays.length === 1 && String(thinkSays[0].text || '').includes('Rule 8'), '退回 say(kind=think)，旧调用方行为不变');
}

console.log('== pickReasoning 的边界 ==');
{
  ok(pickReasoning(null) === '', 'null 安全');
  ok(pickReasoning({}) === '', '没有字段 => 空');
  ok(pickReasoning({ reasoning_content: '  ' }) === '', '空白 => 空');
  ok(pickReasoning({ reasoning_content: ' x ' }) === 'x', '字符串 trim');
  ok(pickReasoning({ reasoning: { effort: 'high' } }) === '', '对象但没有 text/content => 空（不把配置当思考）');
  ok(pickReasoning({ thinking: { content: 'oops' } }) === 'oops', '对象包 content 也认');
  ok(pickReasoning({ reasoning_details: ['a', 'b'] }) === 'a\nb', '数组按行拼');
  ok(pickReasoning({ content: 'thinking in content' }) === '', 'content 永远不算 reasoning');
}

console.log('\n==== reasoning_test: ' + pass + ' 通过, ' + fail + ' 失败 ====');
if (fail > 0) process.exit(1);
