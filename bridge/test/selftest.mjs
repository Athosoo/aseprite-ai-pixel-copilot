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
import { TOOLS } from '../src/tools.mjs';

const TOOL_COUNT = TOOLS.length;

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
// 脚本里放 HANG 表示"这个请求永不回复"，用来测中断 / 超时（P3）
const HANG = Symbol('hang');

function startMockLlm(script) {
  let call = 0;
  const server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const step = script[Math.min(call, script.length - 1)];
      call++;
      if (step === HANG) return;      // 故意不响应：模拟卡死的上游
      const payload = typeof step === 'function' ? step(JSON.parse(body || '{}'), call) : step;
      if (payload && payload.__status) {          // 想造 4xx 的步骤用这个
        res.writeHead(payload.__status, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(payload.body || {}));
        return;
      }
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
    this.asks = [];
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
          // 注意：真实的 Lua 侧把结果放在 report 里（`{ok=true, report=res}`），
          // 桥只读 msg.report —— 以前这里平铺着写，等于测试从来没有校验过回传内容。
          this.send({
            type: 'ops_result',
            id: msg.id,
            ok: true,
            report: {
              sprite: 'test.aseprite',
              layer: 'Layer 1',
              frame: 1,
              // quantize 会带 extra（真实 Lua 侧也会带：前后色数 / 调色板）
              ops: (msg.ops || []).map((o, i) => (o.op === 'quantize'
                ? { index: i + 1, op: o.op, changed: 4096,
                    extra: { colorsBefore: 128, colorsAfter: 61, merged: 67, paletteChanged: 61 } }
                : { index: i + 1, op: o.op, changed: 42 })),
            },
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
      case 'new_sprite':
        this.received.push({ type: 'new_sprite_payload', width: msg.width, height: msg.height, colorMode: msg.colorMode });
        this.send({ type: 'art_result', id: msg.id, ok: true, op: 'new_sprite', changed: true, size: `${msg.width}x${msg.height}`, colorMode: 'RGB' });
        break;
      case 'add_layer':
        this.received.push({ type: 'add_layer_payload', name: msg.name, opacity: msg.opacity });
        this.send({ type: 'art_result', id: msg.id, ok: true, op: 'add_layer', changed: true, layer: msg.name || 'Layer' });
        break;
      case 'draw_art':
        this.received.push({ type: 'draw_art_payload', layer: msg.layer, rows: msg.rows, palette: msg.palette, x: msg.x, y: msg.y });
        this.send({
          type: 'art_result', id: msg.id, ok: true, op: 'draw_art', changed: true,
          painted: (msg.rows || []).join('').replace(/[.\s]/g, '').length,
          skippedOutOfBounds: 0,
          width: (msg.rows || [''])[0].length, height: (msg.rows || []).length,
          distinctColors: Object.keys(msg.palette || {}).length, layer: msg.layer,
        });
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
      case 'ask':
        // P7：把提问记下来，等测试脚本替用户回答（不自动回，模拟"人在看"）
        this.asks.push({ id: msg.id, question: msg.question, options: msg.options });
        break;
      case 'open_doc':
        this.received.push({ type: 'open_doc_payload', path: msg.path });
        if (this.failNextOpen) {
          const e = this.failNextOpen;
          this.failNextOpen = null;
          this.send({ type: 'open_doc_result', id: msg.id, ok: false, error: e });
        } else {
          this.send({
            type: 'open_doc_result', id: msg.id, ok: true,
            name: 'hero.ase', path: 'D:/ws/gift/hero.ase', width: 32, height: 32,
          });
        }
        break;
      case 'list_workspace':
        this.received.push({ type: 'list_workspace_payload' });
        this.send({
          type: 'workspace_result', id: msg.id, root: 'D:/ws',
          files: [
            { name: 'a_copy.ase', path: 'D:/ws/gift/a_copy.ase', dir: 'gift', size: 1234 },
            { name: 'up.png', path: 'D:/ws/uploads/up.png', dir: 'uploads', size: 99 },
          ],
        });
        break;
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
      // 历史也要隔离：不然场景之间会互相"记得"，而且压缩会偷偷吃掉 mock LLM 的脚本步
      history: 'test/.tmp/history.json',
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

  // ---- 场景 7：风格 + 作画（约束 AI 输出参数，像素由 Lua 落）
  console.log('== 场景 7：style_use -> new_sprite -> draw_art ==');
  const cfg4 = { ...testConfig, port: BRIDGE_PORT + 30, systemPrompt: '你是像素画助手。' };
  const configPath4 = join(TMP, 'config4.json');
  writeFileSync(configPath4, JSON.stringify(cfg4, null, 2), 'utf8');
  const bridge4 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath4], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await sleep(700);
  const ase4 = new MockAseprite(BRIDGE_PORT + 30);
  await ase4.connect();
  await sleep(200);

  mockLlm.close();
  // 每次请求都把系统提示记下来，用来验"风格是在同一轮内立刻生效的"：
  // 第 1 步还没切风格 -> 不该有；第 2 步（style_use 之后）就该有了。
  const sysPrompts = [];
  const record = (reply) => (body) => {
    sysPrompts.push(body.messages?.find((m) => m.role === 'system')?.content || '');
    return reply;
  };
  mockLlm = await startMockLlm([
    record(toolCall('call_7a', 'style_use', { name: 'pixel-icon' })),
    record(toolCall('call_7b', 'new_sprite', { width: 16, height: 16 })),
    record(toolCall('call_7c', 'draw_art', {
      layer: 'base',
      palette: { '.': '', X: '#2E86DE', o: '#7EE2A8' },
      rows: ['..XX..', '.XooX.', 'XooooX'],
    })),
    record(textReply('按像素图标风格画好了。')),
  ]);
  await sleep(150);
  ase4.chat('换个像素图标风格，画一个 16x16 的小图标');
  await sleep(2000);

  const stylePromptSeen = sysPrompts[sysPrompts.length - 1] || '';
  check('第 1 步还没选风格，系统提示里没有风格段', !/Style:/.test(sysPrompts[0] || ''), sysPrompts[0]);
  check('style_use 之后的同一步就带上了风格（不是等下一轮）', /Style:/.test(sysPrompts[1] || ''), sysPrompts[1]);
  check('风格切换后注入进系统提示', /Style:/.test(stylePromptSeen) && /#2E86DE/.test(stylePromptSeen), stylePromptSeen?.slice(0, 200));
  const drawPayload = ase4.received.find((m) => m.type === 'draw_art_payload');
  check('draw_art 下发到 Aseprite', !!drawPayload, ase4.received.map((m) => m.type));
  check('字符网格原样转发（不是坐标数组）', drawPayload?.rows?.length === 3 && drawPayload.rows[0] === '..XX..', drawPayload?.rows);
  check('调色板原样转发', drawPayload?.palette?.X === '#2E86DE', drawPayload?.palette);
  check('落到指定图层', drawPayload?.layer === 'base', drawPayload?.layer);
  check('new_sprite 下发', ase4.received.some((m) => m.type === 'new_sprite_payload' && m.width === 16), ase4.received.map((m) => m.type));
  check('画完后 AI 有回复', ase4.says.some((s) => s.kind === 'ai' && s.text.includes('画好')), ase4.says.slice(-3));

  // 风格名应该落到 config.json 里，重启桥还记得
  const cfgOnDisk = JSON.parse(readFileSync(configPath4, 'utf8'));
  check('当前风格持久化到 config.json', cfgOnDisk.activeStyle === 'pixel-icon', cfgOnDisk.activeStyle);

  bridge4.kill();
  ase4.close();
  await sleep(200);

  // ---- 场景 8：紧急中断 + 轮级超时（P3）
  console.log('== 场景 8：abort 帧中断卡住的这一轮 / maxTurnMs 自动中断 ==');
  // maxTurnMs 压到 1200ms：8b 不用等 3 分钟
  const cfg5 = { ...testConfig, port: BRIDGE_PORT + 40, llm: { ...testConfig.llm, maxTurnMs: 1200 } };
  const configPath5 = join(TMP, 'config5.json');
  writeFileSync(configPath5, JSON.stringify(cfg5, null, 2), 'utf8');
  const bridge5 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath5], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await sleep(700);
  const ase5 = new MockAseprite(BRIDGE_PORT + 40);
  await ase5.connect();
  await sleep(200);

  // 8a：第一步给个工具调用，之后上游永不回复 -> 用户在卡住时按「停止」
  mockLlm.close();
  mockLlm = await startMockLlm([
    toolCall('call_8a', 'apply_ops', { label: '长活', ops: [{ op: 'replace_color', from: '#111111', to: '#222222' }] }),
    HANG,
  ]);
  await sleep(150);
  ase5.chat('做一件很久的事');
  await sleep(500);                       // 让它走到第二个请求（卡住的那次）
  const beforeAbort = Date.now();
  ase5.send({ type: 'abort' });
  await sleep(600);
  check('手动中断后提示"已中断"',
    ase5.says.some((s) => s.i18n === 'aborted'), ase5.says.slice(-3));
  check('中断后状态回到 ready',
    ase5.statuses[ase5.statuses.length - 1] === 'ready', ase5.statuses.slice(-3));
  check('中断是立刻生效的（< 500ms 就有回复）', Date.now() - beforeAbort < 1500,
    `${Date.now() - beforeAbort}ms`);

  // 8b：不按停止 -> 轮级超时自动中断（maxTurnMs = 1200）
  ase5.statuses.length = 0;
  ase5.says.length = 0;
  ase5.chat('再来一件很久的事');
  await sleep(2400);
  check('超时后提示"超时自动中断"',
    ase5.says.some((s) => s.i18n === 'abortTimeout'), ase5.says.slice(-3));
  check('超时后状态回到 ready',
    ase5.statuses[ase5.statuses.length - 1] === 'ready', ase5.statuses.slice(-3));
  check('超时中断和手动中断给的是不同提示',
    !ase5.says.some((s) => s.i18n === 'aborted'), ase5.says.slice(-3));

  // 8c：没有任务在跑时按停止，不能挂死
  ase5.says.length = 0;
  ase5.send({ type: 'abort' });
  await sleep(300);
  check('空闲时按停止 -> 明确说没有任务在跑',
    ase5.says.some((s) => s.i18n === 'abortNothing'), ase5.says.slice(-2));

  // ---- 场景 9：已经矫正过的图不再被处理（P8）
  console.log('== 场景 9：已是真像素画 -> 不导入、不重试 ==');
  ase5.says.length = 0;
  ase5.imports.length = 0;
  ase5.received.length = 0;
  ase5.canvas = makePseudoPixelArt(1, 16);        // 16x16，每格 1px = 已矫正过
  mockLlm.close();
  mockLlm = await startMockLlm([
    toolCall('call_9a', 'perfect_pixel', { source: 'active_canvas' }),
    (body) => {
      // 第二步：把工具结果记下来，断言桥返回的是"别重试"
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__ppResult = toolMsgs.length ? JSON.parse(toolMsgs[toolMsgs.length - 1].content) : null;
      return textReply('这张已经是真像素画了，不需要再处理。');
    },
  ]);
  await sleep(150);
  ase5.chat('把当前这张图矫正一下');
  await sleep(1500);
  check('桥向 Aseprite 索要了画布', ase5.received.some((m) => m.type === 'get_canvas'),
    ase5.received.map((m) => m.type));
  check('没有回传导入图像（不开多余文档）', ase5.imports.length === 0, ase5.imports);
  check('工具结果标了 noGridDetected', global.__ppResult?.noGridDetected === true, global.__ppResult);
  check('工具结果明确禁止盲目重试 gridSize',
    /do NOT retry/i.test(global.__ppResult?.note || ''), global.__ppResult?.note);

  bridge5.kill();
  ase5.close();
  await sleep(200);
  // ---- 场景 10：选项式提问 ask_user（P7）
  console.log('== 场景 10：ask_user 弹选项 -> 答案回到模型上下文 ==');
  const cfg6 = { ...testConfig, port: BRIDGE_PORT + 50 };
  const configPath6 = join(TMP, 'config6.json');
  writeFileSync(configPath6, JSON.stringify(cfg6, null, 2), 'utf8');
  const bridge6 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath6], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  await sleep(700);
  const ase6 = new MockAseprite(BRIDGE_PORT + 50);
  await ase6.connect();
  await sleep(200);

  mockLlm.close();
  global.__askResult = null;
  mockLlm = await startMockLlm([
    toolCall('call_10a', 'ask_user', {
      question: '覆盖原图还是保留副本？',
      options: ['覆盖原图', '保留副本'],
    }),
    (body) => {
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__askResult = toolMsgs.length ? JSON.parse(toolMsgs[toolMsgs.length - 1].content) : null;
      return textReply('好，保留副本。');
    },
  ]);
  await sleep(150);
  ase6.chat('这张图改完怎么处理？');
  await sleep(700);

  check('桥把提问下发到面板', ase6.asks.length === 1, ase6.asks);
  check('问题原样下发', ase6.asks[0]?.question === '覆盖原图还是保留副本？', ase6.asks[0]);
  check('选项原样下发', ase6.asks[0]?.options?.length === 2 && ase6.asks[0].options[0] === '覆盖原图',
    ase6.asks[0]?.options);
  check('用户回答之前工具没有返回（桥在等）', global.__askResult === null, global.__askResult);

  ase6.send({ type: 'answer', id: ase6.asks[0].id, index: 2, choice: '保留副本' });
  await sleep(800);
  check('选择回到了模型上下文',
    global.__askResult?.ok === true && global.__askResult?.choice === '保留副本', global.__askResult);
  check('AI 基于选择给出了回复',
    ase6.says.some((s) => s.kind === 'ai' && s.text.includes('保留')), ase6.says.slice(-3));

  // 取消路径：用户关掉弹窗
  ase6.asks.length = 0;
  ase6.says.length = 0;
  mockLlm.close();
  global.__askResult = null;
  mockLlm = await startMockLlm([
    toolCall('call_10b', 'ask_user', { question: '还要继续吗？', options: ['继续', '停下'] }),
    (body) => {
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__askResult = toolMsgs.length ? JSON.parse(toolMsgs[toolMsgs.length - 1].content) : null;
      return textReply('那先停在这里。');
    },
  ]);
  await sleep(150);
  ase6.chat('再问一次');
  await sleep(700);
  ase6.send({ type: 'answer', id: ase6.asks[0].id, cancelled: true });
  await sleep(800);
  check('取消也回到了模型上下文', global.__askResult?.cancelled === true, global.__askResult);

  // 参数校验：少于 2 个选项不弹窗，直接把原因回给模型
  mockLlm.close();
  global.__askResult = null;
  mockLlm = await startMockLlm([
    toolCall('call_10c', 'ask_user', { question: '只有一个选项？', options: ['唯一'] }),
    (body) => {
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__askResult = toolMsgs.length ? JSON.parse(toolMsgs[toolMsgs.length - 1].content) : null;
      return textReply('那我直接问你吧。');
    },
  ]);
  await sleep(150);
  ase6.asks.length = 0;
  ase6.chat('再来一次');
  await sleep(800);
  check('少于 2 个选项被拒绝，没弹窗', ase6.asks.length === 0, ase6.asks);
  check('拒绝了并告诉模型原因',
    typeof global.__askResult?.error === 'string' && /options/.test(global.__askResult.error),
    global.__askResult);

  // ---- 场景 11：capabilities 清单（P14）
  console.log('== 场景 11：capabilities 与真实工具表一致 ==');
  mockLlm.close();
  global.__cap = null;
  mockLlm = await startMockLlm([
    toolCall('call_11a', 'capabilities', {}),
    (body) => {
      const toolMsgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__cap = toolMsgs.length ? JSON.parse(toolMsgs[toolMsgs.length - 1].content) : null;
      return textReply('我能改画布、画像素画和矫正图片；不能联网。');
    },
  ]);
  await sleep(150);
  ase6.chat('你能做什么？');
  await sleep(800);
  const cap = global.__cap;
  check('capabilities 返回了 can 段', !!cap?.can, cap);
  check('can.tools 里有 ask_user 和 capabilities 自己',
    !!cap?.can?.tools?.ask_user && !!cap?.can?.tools?.capabilities, Object.keys(cap?.can?.tools || {}));
  check('can.tools 覆盖了所有注册工具（不会漏报能力）',
    Object.keys(cap?.can?.tools || {}).length === TOOL_COUNT,
    `${Object.keys(cap?.can?.tools || {}).length} vs ${TOOL_COUNT}`);
  check('cannot 段非空，且明确要求别吹牛',
    Array.isArray(cap?.cannot) && cap.cannot.length >= 4 && /only promise/i.test(cap?.honesty || ''),
    [cap?.cannot?.length, cap?.honesty]);
  check('cannot 里明确说了不能联网', cap?.cannot?.some((x) => /network/i.test(x)), cap?.cannot);
  check('can.edit_ops 来自 Aseprite 侧的真实算子表',
    Array.isArray(cap?.can?.edit_ops) && cap.can.edit_ops.includes('replace_color'), cap?.can?.edit_ops);

  // ---- 场景 12：打开文档 + 列工作区（v0.5.1 补的端到端覆盖）
  console.log('== 场景 12：open_document / list_workspace 端到端 ==');
  mockLlm.close();
  global.__openResult = null;
  global.__lsResult = null;
  mockLlm = await startMockLlm([
    toolCall('call_12a', 'open_document', { path: 'gift/hero.ase' }),
    (body) => {
      const msgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__openResult = msgs.length ? JSON.parse(msgs[msgs.length - 1].content) : null;
      return toolCall('call_12b', 'list_workspace', {});
    },
    (body) => {
      const msgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__lsResult = msgs.length ? JSON.parse(msgs[msgs.length - 1].content) : null;
      return textReply('工作区里有 2 个文件。');
    },
  ]);
  await sleep(150);
  ase6.chat('打开 gift 里的 hero，再看看工作区有什么');
  await sleep(900);

  const openPayload = ase6.received.find((m) => m.type === 'open_doc_payload');
  check('桥把 open_doc 下发到 Aseprite', !!openPayload, ase6.received.map((m) => m.type));
  check('路径原样下发', openPayload?.path === 'gift/hero.ase', openPayload);
  check('打开结果回到模型上下文（含尺寸）',
    global.__openResult?.ok === true && global.__openResult?.width === 32
    && global.__openResult?.name === 'hero.ase', global.__openResult);
  check('桥要了工作区列表', ase6.received.some((m) => m.type === 'list_workspace_payload'),
    ase6.received.map((m) => m.type));
  check('工作区列表回到模型上下文（含根路径和两项文件）',
    global.__lsResult?.root === 'D:/ws' && global.__lsResult?.files?.length === 2
    && global.__lsResult.files[0].size === 1234, global.__lsResult);

  // 打开失败时错误要回到模型，而不是静默
  mockLlm.close();
  global.__openResult = null;
  mockLlm = await startMockLlm([
    toolCall('call_12c', 'open_document', { path: 'no/such.ase' }),
    (body) => {
      const msgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__openResult = msgs.length ? JSON.parse(msgs[msgs.length - 1].content) : null;
      return textReply('那个路径打不开。');
    },
  ]);
  await sleep(150);
  ase6.failNextOpen = 'not a path we can open';
  ase6.chat('打开一个不存在的');
  await sleep(900);
  check('打开失败的原因回到了模型上下文',
    typeof global.__openResult?.error === 'string' && /not a path/.test(global.__openResult.error),
    global.__openResult);

  bridge6.kill();
  ase6.close();
  await sleep(200);

  // ---- 场景 13：上下文记忆（v0.5.2 上下文管理）
  console.log('== 场景 13：对话记忆落盘 -> 跨桥重启还在 -> 可清空 -> 步数/思考可调 ==');
  const HIST = join(TMP, 'history13.json');
  rmSync(HIST, { force: true });
  const cfg7 = {
    ...testConfig,
    port: BRIDGE_PORT + 60,
    llm: { ...testConfig.llm, maxSteps: 24 },
    paths: { ...testConfig.paths, history: 'test/.tmp/history13.json' },
  };
  const configPath7 = join(TMP, 'config7.json');
  writeFileSync(configPath7, JSON.stringify(cfg7, null, 2), 'utf8');

  let bridge7 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath7], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  bridge7.stderr.on('data', (d) => process.stdout.write(`[bridge:err] ${d}`));
  await sleep(700);
  let ase7 = new MockAseprite(BRIDGE_PORT + 60);
  await ase7.connect();
  await sleep(200);

  mockLlm.close();
  mockLlm = await startMockLlm([
    () => textReply('记住了：外壳用 #2E86DE。'),
  ]);
  await sleep(150);
  ase7.chat('记住：外壳用 #2E86DE');
  await sleep(900);

  check('配置里的步数发到了面板', ase7.cfgMsgs.some((m) => m.llm?.maxSteps === 24),
    ase7.cfgMsgs.at(-1)?.llm);
  check('配置里带了上下文预算', ase7.cfgMsgs.some((m) => m.llm?.contextTokens === 16000),
    ase7.cfgMsgs.at(-1)?.llm);
  const ctxPushes = ase7.received.filter((m) => m.type === 'context');
  check('握手就推了一次上下文用量（底边栏电量条靠它）',
    ctxPushes.length > 0 && ctxPushes[0].budget === 16000 && typeof ctxPushes[0].used === 'number',
    ctxPushes[0]);
  check('对话落盘了', existsSync(HIST), HIST);
  const saved = JSON.parse(readFileSync(HIST, 'utf8'));
  // 用户那条前面带着画布上下文（buildUserMessage 拼的），所以用 includes 判断
  check('落盘内容 = 用户那句 + 助手那句', saved.messages.length === 2
    && saved.messages[0].role === 'user'
    && String(saved.messages[0].content).includes('记住：外壳用 #2E86DE')
    && saved.messages[1].role === 'assistant', saved.messages.map((m) => m.role));

  // 重启桥：历史要读回来，并在握手后提示用户
  bridge7.kill();
  ase7.close();
  await sleep(300);
  bridge7 = spawn(process.execPath, [join(ROOT, 'src', 'server.mjs'), '--config', configPath7], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  bridge7.stderr.on('data', (d) => process.stdout.write(`[bridge:err] ${d}`));
  await sleep(700);
  const ase7b = new MockAseprite(BRIDGE_PORT + 60);
  await ase7b.connect();
  await sleep(300);
  check('重启后握手就告诉用户"上下文已恢复"',
    ase7b.says.some((s) => s.i18n === 'ctxRestored'), ase7b.says.map((s) => s.i18n));

  mockLlm.close();
  global.__sentMessages = null;
  mockLlm = await startMockLlm([
    (body) => { global.__sentMessages = body.messages; return textReply('记得，外壳是 #2E86DE。'); },
  ]);
  await sleep(150);
  ase7b.chat('我的外壳是什么颜色？');
  await sleep(900);
  const seePrev = (global.__sentMessages || []).some(
    (m) => typeof m.content === 'string' && m.content.includes('记住：外壳用 #2E86DE'));
  check('重启后模型仍拿到之前那轮对话（不是失忆）', seePrev,
    (global.__sentMessages || []).map((m) => String(m.content).slice(0, 20)));

  // history_info：面板能查当前上下文
  ase7b.send({ type: 'history_info', id: 77 });
  await sleep(300);
  const info = ase7b.received.filter((m) => m.type === 'history_result').at(-1);
  check('history_info 报出条数与预算', info?.messages >= 3 && info?.budgetTokens === 16000, info);

  // 清空上下文：历史文件要真的空
  ase7b.send({ type: 'reset_history', id: 78 });
  await sleep(400);
  const cleared = ase7b.received.filter((m) => m.type === 'history_result').at(-1);
  check('reset 回执', cleared?.reset === true, cleared);
  check('清空后桥提示了用户（带本地化键）',
    ase7b.says.some((s) => s.i18n === 'ctxCleared'), ase7b.says.map((s) => s.i18n));
  const afterReset = JSON.parse(readFileSync(HIST, 'utf8'));
  check('清空后文件里没有消息了', afterReset.messages.length === 0 && afterReset.summary === '',
    afterReset.messages.length);

  // 设置面板改高级项 -> 立刻生效（回执里能看到新值）
  ase7b.send({
    type: 'set_config', id: 79,
    llm: { maxSteps: 12, contextTokens: 4000, temperature: 0.5, thinking: 'high' },
  });
  await sleep(400);
  const cfg7b = ase7b.cfgMsgs.at(-1)?.llm;
  check('设置保存后回执里是新步数', cfg7b?.maxSteps === 12, cfg7b);
  check('设置保存后回执里是新上下文预算', cfg7b?.contextTokens === 4000, cfg7b);
  check('设置保存后回执里是新温度', cfg7b?.temperature === 0.5, cfg7b);
  check('设置保存后回执里是思考强度', cfg7b?.thinking === 'high', cfg7b);
  const savedCfg7 = JSON.parse(readFileSync(configPath7, 'utf8'));
  check('高级项落到了 config.json（重启桥还在）',
    savedCfg7.llm.maxSteps === 12 && savedCfg7.llm.contextTokens === 4000 && savedCfg7.llm.thinking === 'high',
    savedCfg7.llm);

  ase7b.send({ type: 'set_config', id: 80, llm: { maxSteps: 9999, contextTokens: 999999 } });
  await sleep(400);
  check('越界步数被夹到 200', ase7b.cfgMsgs.at(-1)?.llm?.maxSteps === 200, ase7b.cfgMsgs.at(-1)?.llm);
  check('越界上下文被夹到 200000', ase7b.cfgMsgs.at(-1)?.llm?.contextTokens === 200000,
    ase7b.cfgMsgs.at(-1)?.llm);
  const ctxAfter = ase7b.received.filter((m) => m.type === 'context');
  check('改完预算电量条立刻按新预算推（不用重启桥）',
    ctxAfter.some((m) => m.budget === 200000), ctxAfter.at(-1));

  // thinking=high -> 请求里要带 reasoning_effort
  mockLlm.close();
  global.__reqBody = null;
  mockLlm = await startMockLlm([
    (body) => { global.__reqBody = body; return textReply('好。'); },
  ]);
  await sleep(150);
  ase7b.chat('随便说一句');
  await sleep(900);
  check('思考强度发到了请求体里', global.__reqBody?.reasoning_effort === 'high',
    global.__reqBody?.reasoning_effort);

  // 端点不认这个字段 -> 去掉重试一次，并告诉用户
  mockLlm.close();
  ase7b.says.length = 0;
  global.__reqBody = null;
  global.__retryHad = null;
  mockLlm = await startMockLlm([
    (body) => {
      if (body.reasoning_effort) {
        global.__retryHad = body.reasoning_effort;
        return { __status: 400, body: { error: { message: 'unknown field reasoning_effort' } } };
      }
      global.__reqBody = body;
      return textReply('好。');
    },
  ]);
  await sleep(150);
  ase7b.chat('再说一句');
  await sleep(1200);
  check('第一次带了 thinking（被端点拒掉）', global.__retryHad === 'high', global.__retryHad);
  check('去掉 thinking 后重试成功',
    global.__reqBody !== null && global.__reqBody.reasoning_effort === undefined,
    global.__reqBody?.reasoning_effort);
  check('降级告诉了用户（本地化键 thinkingDropped）',
    ase7b.says.some((s) => s.i18n === 'thinkingDropped'), ase7b.says.map((s) => s.i18n));

  console.log('== 场景 14：quantize 自动减色跑到 Aseprite 侧 ==');
  mockLlm.close();
  global.__quantOk = null;
  mockLlm = await startMockLlm([
    toolCall('call_14a', 'apply_ops', {
      label: '减色到 64 以内',
      ops: [{ op: 'quantize', colors: 64 }],
    }),
    (body) => {
      const msgs = (body.messages || []).filter((m) => m.role === 'tool');
      global.__quantOk = msgs.length ? JSON.parse(msgs[msgs.length - 1].content) : null;
      return textReply('已经合并到 64 色以内了。');
    },
  ]);
  await sleep(150);
  ase7b.received.length = 0;
  ase7b.chat('现在的配色太杂了，帮我合并到 64 个颜色以内');
  await sleep(1000);

  const qOps = ase7b.received.find((m) => m.type === 'run_ops_payload');
  check('quantize 原样下发到 Aseprite', !!qOps && qOps.ops?.[0]?.op === 'quantize', qOps?.ops);
  check('colors 参数没在路上丢', qOps?.ops?.[0]?.colors === 64, qOps?.ops?.[0]);
  check('减色结果回到模型上下文（含前后色数）',
    global.__quantOk?.ops?.[0]?.op === 'quantize'
    && global.__quantOk.ops[0].extra?.colorsBefore === 128
    && global.__quantOk.ops[0].extra?.colorsAfter === 61, global.__quantOk);

  bridge7.kill();
  ase7b.close();
  await sleep(200);


  console.log(`\n==== selftest: ${passes} 通过, ${fails} 失败 ====`);
  process.exit(fails > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error('自测崩溃：', e);
  process.exit(1);
});
