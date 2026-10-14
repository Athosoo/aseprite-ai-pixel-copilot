// 测试用 mock LLM：脚本化返回 tool_call / 最终文本，不消耗真实 token
// 用法： node test/mock_llm.mjs [port]

import { createServer } from 'node:http';

const port = Number(process.argv[2] || 8792);

const script = [
  {
    choices: [{
      message: {
        role: 'assistant',
        content: '好的，我把画布上的红色换成蓝色。',
        tool_calls: [{
          id: 'call_1',
          type: 'function',
          function: {
            name: 'apply_ops',
            arguments: JSON.stringify({
              label: '红色换蓝色',
              ops: [{ op: 'replace_color', from: '#FF0000', to: '#0000FF' }],
            }),
          },
        }],
      },
    }],
  },
  {
    choices: [{
      message: { role: 'assistant', content: '已经换好了：红色像素全部变成蓝色。' },
    }],
  },
];

let call = 0;
createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    const step = script[Math.min(call, script.length - 1)];
    call++;
    console.log(`[mock-llm] 第 ${call} 次请求 -> 返回 ${step.choices[0].message.tool_calls ? 'tool_call' : '文本'}`);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(step));
  });
}).listen(port, '127.0.0.1', () => console.log(`[mock-llm] 监听 ${port}`));
