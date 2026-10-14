// 端到端自测：不需要 Aseprite，也不需要真的 LLM。
//
//   node test/selftest.mjs
//
// 起三个东西：
//   1) mock LLM 服务（脚本化返回 tool_call / 最终文本）
//   2) 真正的桥 src/server.mjs（用临时 config）
//   3) mock Aseprite 客户端（用 WebSocket 冒充 Lua 扩展那一侧）
// 然后跑几个场景，断言消息链路正确。

import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import WebSocket from 'ws';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const TMP = join(ROOT, 'test', '.tmp');

const BRIDGE_PORT = 8791;
const LLM_PORT = 8792;

let passes = 0;
let fails = 0;
function check(name, cond, extra) {
  if (cond) {
    passes++;
    console.log(`  ok   ${name}`);
  } else {
    fails++;
    console.log(`  FAIL ${name}${extra !== undefined ? `   <- ${JSON.stringify(extra)}` : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------ 造一张伪像素画
// 逻辑 16x16，用整数倍放大成 64x64（PerfectPixel 应该能检测出 16x16 网格）
function makePseudoPixelArt(scale = 4, logical = 16) {
  const size = scale * logical;
  const data = new Uint8Array(size * size * 4);
  const palette = [
    [229, 57, 53],
    [46, 134, 222],
    [255, 224, 189],
    [74, 52, 40],
    [126, 211, 33],
  ];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const lx = Math.floor(x / scale);
      const ly = Math.floor(y / scale);
      // 用逻辑坐标做点结构：圆 + 横条，保证有明确的格子边界
      const inCircle = (lx - 8) ** 2 + (ly - 8) ** 2 < 36;
      const idx = inCircle ? ((lx + ly) % 3) + 1 : 0;
      const [r, g, b] = palette[idx];
      const o = (y * size + x) * 4;
      data[o] = r;
      data[o + 1] = g;
      data[o + 2] = b;
      data[o + 3] = 255;
    }
  }
  return { data, size };
}

// ------------------------------------------------------------ mock LLM
function startMockLlm(script) {
  let call = 0;
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const step = script[Math.min(call, script.length - 1)];
      call++;
      const payload = typeof step === 'function' ? step(JSON.parse(body || '{}'), call) : step;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(payload));
    });
  });
  return new Promise((resolve) => server.listen(LLM_PORT, '127.0.0.1', () => resolve(server)));
}

function toolCall(id, name, args) {
  return {
    choices: [
      {
        message: {
          role: 'assistant',
          content: '',
          tool_calls: [
            { id, type: 'function', function: { name, arguments: JSON.stringify(args) } },
          ],
        },
      },
    ],
  };
}

function textReply(text) {
  return { choices: [{ message: { role: 'assistant', content: text } }] };
}

// ------------------------------------------------------------ mock Aseprite
class MockAseprite {
  constructor(port) {
    this.port = port;
    this.received = [];
    this.says = [];
    this.statuses = [];
    this.imports = [];
    this.autoReply = true;
    this.canvas = null;
    this.failNextOps = null;
    this.cfgMsgs = [];
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`ws://127.0.0.1:${this.port}`);
      this.ws.on('open', () => {
        this.send({
          type: 'hello',
          aseprite: '1.3.18.6-dev',
          apiVersion: 41,
          ops: ['replace_color', 'erase_color', 'erase_region', 'fill_region', 'outline', 'despeckle', 'palette_map'],
        });
        resolve();
      });
      this.ws.on('error', reject);
      this.ws.on('message', (data, isBinary) => this.onMessage(data, isBinary));
    });
  }

  send(obj) {
    if (this.ws.readyState === 1) this.ws.send(JSON.stringify(obj));
  }

  sendBinary(header, buf) {
    this.send(header);
    this.ws.send(Buffer.from(buf), { binary: true });
  }

  onMessage(data, isBinary) {
    if (isBinary) {
      this.received.push({ type: 'binary', length: data.length, header: this.lastHeader });
      if (this.lastHeader?.type === 'import_image') {
        this.imports.push({ width: this.lastHeader.width, height: this.lastHeader.height, length: data.length });
      }
      return;
    }
    const msg = JSON.parse(data.toString('utf8'));
    this.received.push(msg);
    if (msg.type === 'say') this.says.push(msg);
    if (msg.type === 'status') this.statuses.push(msg.text);
    if (msg.type === 'config') { this.cfgMsgs.push(msg); if (this.onConfig) this.onConfig(msg); }

    if (!this.autoReply) return;

    switch (msg.type) {
      case 'run_ops': {
        this.received.push({ type: 'run_ops_payload', ops: msg.ops, label: msg.label });
        if (this.failNextOps) {
          const err = this.failNextOps;
          this.failNextOps = null;
          this.send({ type: 'ops_result', id: msg.id, ok: false, error: err });
        } else {
          this.send({
            type: 'ops_result',
            id: msg.id,
            ok: true,
            sprite: 'test.aseprite',
            layer: 'Layer 1',
            frame: 1,
            ops: (msg.ops || []).map((o, i) => ({ index: i + 1, op: o.op, changed: 42 })),
          });
        }
        break;
      }
      case 'snapshot':
        this.send({ type: 'snapshot_result', id: msg.id, ok: true, id2: 1, label: msg.label, date: '2026-10-12 23:00:00', cels: 1 });
        break;
      case 'rollback':
        this.send({ type: 'rollback_result', id: msg.id, ok: true, id2: Number(msg.to) || 1, label: 'v1', matched: 1, total: 1, missing: [] });
        break;
      case 'list_versions':
        this.send({ type: 'versions', id: msg.id, list: [{ id: 1, label: '初始', date: '2026-10-12 22:00:00', cels: 1 }] });
        break;
      case 'canvas_info':
        this.send({ type: 'canvas_info_result', id: msg.id, context: this.context() });
        break;
      case 'get_canvas': {
        const c = this.canvas;
        this.lastHeader = { type: 'canvas_pixels', id: msg.id, width: c.size, height: c.size };
        this.sendBinary(
          { type: 'canvas_pixels', id: msg.id, width: c.size, height: c.size },
          c.data,
        );
        break;
      }
      case 'import_image':
        this.lastHeader = msg;
        break;
      default:
        break;
    }
  }

  context() {
    return {
      hasSprite: true,
      sprite: { name: 'test.aseprite', width: 64, height: 64, colorMode: 0, layers: ['Layer 1'], frames: 1 },
      layer: 'Layer 1',
      frame: 1,
      colors: [{ hex: '#E53935', count: 100 }, { hex: '#2E86DE', count: 80 }],
      totalPixels: 4096,
      opaquePixels: 180,
      versionCount: 0,
    };
  }

  chat(text) {
    this.send({ type: 'chat', id: 999, text, context: this.context() });
  }

  close() {
    if (this.ws) this.ws.close();
  }
}

// ------------------------------------------------------------ 跑
async function main() {
  rmSync(TMP, { recursive: true, force: true });
  mkdirSync(TMP, { recursive: true });

  const testConfig = {
    port: BRIDGE_PORT,
    llm: {
      baseUrl: `http://127.0.0.1:${LLM_PORT}/v1`,
      apiKey: 'test-key',
      model: 'mock-model',
      temperature: 0,
      maxSteps: 6,
      timeoutMs: 20000,
    },
    systemPrompt: '测试用系统提示。',
    paths: {
      perfectPixelBundle: 'vendor/perfectPixel.mjs',
      colorBank: `test/.tmp/colors.json`,
    },
  };
  const configPath = join(TMP, 'config.json');
  writeFileSync(configPath, JSON.stringify(testConfig, null, 2), 'utf8');

  // ---- 场景 1：换色链路
  console.log('== 场景 1：自然语言 -> apply_ops -> Aseprite 执行 ==');
  let mockLlm = await startMockLlm([
    toolCall('call_1', 'apply_ops', {
      label: '背景换蓝',
      ops: [{ op: 'replace_color', from: '#FF0000', to: '#2E86DE' }],
    }),
    textReply('已把背景的红色换成蓝色。'),
  ]);

  let bridge = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  bridge.stdout.on('data', (d) => process.env.VERBOSE && process.stdout.write(`[bridge] ${d}`));
  bridge.stderr.on('data', (d) => process.stdout.write(`[bridge:err] ${d}`));
  await sleep(700);

  let ase = new MockAseprite(BRIDGE_PORT);
  await ase.connect();
  await sleep(200);

  ase.chat('把背景的红色换成蓝色');
  await sleep(1200);

  const runOps = ase.received.find((m) => m.type === 'run_ops_payload');
  check('桥把算子下发到 Aseprite', !!runOps, runOps);
  check('算子内容正确', runOps && runOps.ops[0].op === 'replace_color' && runOps.ops[0].from === '#FF0000' && runOps.ops[0].to === '#2E86DE', runOps);
  check('label 正确', runOps && runOps.label === '背景换蓝', runOps?.label);
  const aiSay = ase.says.filter((s) => s.kind === 'ai');
  check('AI 最终回复推送到面板', aiSay.some((s) => s.text.includes('蓝色')), ase.says);

  // ---- 场景 2：算子失败时错误回传
  console.log('== 场景 2：Aseprite 拒绝操作时，错误回到模型 ==');
  ase.failNextOps = '未知算子 foo';
  mockLlm.close();
  mockLlm = await startMockLlm([
    toolCall('call_2', 'apply_ops', { label: '乱来', ops: [{ op: 'foo' }] }),
    textReply('那个操作不支持，我换个方式。'),
  ]);
  await sleep(150);
  ase.chat('随便搞一下');
  await sleep(1200);
  check('失败后 AI 仍给出回复', ase.says.filter((s) => s.kind === 'ai').length >= 2, ase.says.length);

  // ---- 场景 3：Perfect Pixel 矫正当前画布
  console.log('== 场景 3：perfect_pixel 矫正 -> 导入为新文档 ==');
  const art = makePseudoPixelArt(4, 16);
  ase.canvas = art;
  mockLlm.close();
  mockLlm = await startMockLlm([
    toolCall('call_3', 'perfect_pixel', { source: 'active_canvas' }),
    textReply('网格检测成功，已经作为新文档打开了。'),
  ]);
  await sleep(150);
  ase.chat('把当前这张糊图矫正成真像素画');
  await sleep(3000);

  check('桥向 Aseprite 索要了画布像素', ase.received.some((m) => m.type === 'get_canvas'), ase.received.map((m) => m.type));
  check('桥回传了导入图像', ase.imports.length === 1, ase.imports);
  if (ase.imports.length) {
    const imp = ase.imports[0];
    check(`导入尺寸是 16x16（实际 ${imp.width}x${imp.height}）`, imp.width === 16 && imp.height === 16, imp);
    check('导入数据长度匹配 16*16*4', imp.length === 16 * 16 * 4, imp.length);
  }
  check('AI 报告矫正成功', ase.says.some((s) => s.kind === 'ai' && s.text.includes('新文档')), ase.says.slice(-3));

  // ---- 场景 4：色值记忆
  console.log('== 场景 4：色值记忆 remember_color / search_colors ==');
  mockLlm.close();
  mockLlm = await startMockLlm([
    toolCall('call_4a', 'remember_color', { hex: '#2E86DE', scene: '蓝色外壳主体', tags: ['外壳', '蓝'], note: '16x16 图标' }),
    toolCall('call_4b', 'search_colors', { query: '外壳' }),
    (body) => {
      // 第三个请求：断言工具结果里确实带回了记住的颜色
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      const last = toolMsgs[toolMsgs.length - 1];
      global.__searchResult = last ? JSON.parse(last.content) : null;
      return textReply('你之前用 #2E86DE 做蓝色外壳主体。');
    },
  ]);
  await sleep(150);
  ase.chat('记住这个颜色，然后查一下我之前的外壳色');
  await sleep(1500);
  check('search_colors 能查到刚记的颜色', global.__searchResult?.entries?.some((e) => e.hex === '#2E86DE'), global.__searchResult);
  check('色值库落盘', existsSync(join(TMP, 'colors.json')), join(TMP, 'colors.json'));

  // ---- 场景 5：没有 API Key 时的提示
  console.log('== 场景 5：缺 API Key 时的报错 ==');
  bridge.kill();
  await sleep(300);
  const cfg2 = { ...testConfig, port: BRIDGE_PORT + 10, llm: { ...testConfig.llm, apiKey: '' } };
  const configPath2 = join(TMP, 'config2.json');
  writeFileSync(configPath2, JSON.stringify(cfg2, null, 2), 'utf8');
  const bridge2 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath2], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await sleep(700);
  const ase2 = new MockAseprite(BRIDGE_PORT + 10);
  await ase2.connect();
  await sleep(200);
  ase2.chat('你好');
  await sleep(600);
  check('提示要填 API Key', ase2.says.some((s) => s.kind === 'error' && /api key/i.test(s.text)), ase2.says);
  bridge2.kill();
  ase2.close();
  ase.close();

  // ---- 场景 6：插件内配置 API（get_config / set_config / test_llm）
  console.log('== 场景 6：插件内配置 API ==');
  const cfg3 = { ...testConfig, port: BRIDGE_PORT + 20, llm: { ...testConfig.llm, apiKey: 'sk-initial-key-abc' } };
  const configPath3 = join(TMP, 'config3.json');
  writeFileSync(configPath3, JSON.stringify(cfg3, null, 2), 'utf8');
  const bridge3 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath3], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await sleep(700);
  const ase3 = new MockAseprite(BRIDGE_PORT + 20);
  await ase3.connect();
  await sleep(400);
  check('hello 后自动推送 config', ase3.cfgMsgs.length >= 1, ase3.cfgMsgs.length);
  check('config 带 apiKeySet=true', ase3.cfgMsgs[0]?.llm?.apiKeySet === true, ase3.cfgMsgs[0]?.llm);
  check('config 不外泄完整 key', !JSON.stringify(ase3.cfgMsgs[0]).includes('sk-initial-key-abc'), ase3.cfgMsgs[0]?.llm);

  ase3.send({ type: 'set_config', llm: { model: 'new-model-x', apiKey: 'sk-new-key-1234567890' } });
  await sleep(400);
  const savedCfg = ase3.cfgMsgs[ase3.cfgMsgs.length - 1];
  check('set_config 回推新 model', savedCfg?.llm?.model === 'new-model-x', savedCfg?.llm);
  const onDisk = JSON.parse(readFileSync(configPath3, 'utf8'));
  check('新 model 已落盘', onDisk.llm.model === 'new-model-x', onDisk.llm.model);
  check('新 key 已落盘', onDisk.llm.apiKey === 'sk-new-key-1234567890', onDisk.llm.apiKey);
  check('保留 systemPrompt', typeof onDisk.systemPrompt === 'string' && onDisk.systemPrompt.length > 0);

  ase3.send({ type: 'set_config', llm: { apiKey: '' } });
  await sleep(300);
  const after2 = JSON.parse(readFileSync(configPath3, 'utf8'));
  check('空 apiKey = 保持不变', after2.llm.apiKey === 'sk-new-key-1234567890', after2.llm.apiKey);

  ase3.send({ type: 'test_llm' });
  await sleep(900);
  check('test_llm 返回结果', ase3.says.some((x) => /Connection OK|Connection failed/.test(x.text)), ase3.says.slice(-2));
  bridge3.kill();
  ase3.close();

  await sleep(200);
  console.log(`\n==== selftest: ${passes} 通过, ${fails} 失败 ====`);
  process.exit(fails > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error('自测崩溃：', e);
  process.exit(1);
});
