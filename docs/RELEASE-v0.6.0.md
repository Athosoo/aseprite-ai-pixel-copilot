# v0.6.0 发布说明（先发，不完美）

> 定位：**可用性重建**。把「在 Aseprite 里和 AI 对话、由 AI 调用 Aseprite 能力」这条主链路打通并验证，
> 同时把内核重构成可扩展结构。它**还不是完成的 UI**，已知问题在最后一节列清楚。

---

## 一、这版能做什么（都经过真机验证）

| 能力 | 状态 | 证据 |
|---|---|---|
| 面板内和模型对话 | ✅ | 桥 health `clients: 1`；ws 直连探针收到回复并回到 ready |
| 配置持久化（端点/模型/密钥） | ✅ | 日志 `Settings: model=deepseek-chat … apiKey=set sk-****f8e5` 写回 bridge/config.json |
| 设置页在面板内编辑（不再弹旧窗口） | ✅ | 10 个字段，回车保存 / Esc 取消 / 未连接时直说无法保存 |
| AI 提问后作答 | ✅ | 输入编号作答、取消词取消、自由文本先取消再发出 |
| 模型的思考与正文分离 | ✅ | 思考走独立 thinking 帧，面板用弱化色显示 |
| 画布算子 | ✅ | 10 个算子（含 sharpen / contrast），一步撤销 |
| 能力包体系（自扩展） | ✅ | 注册表 + 热装载 + propose/verify/activate/rollback，五条护栏各有断言 |
| 旧终端面板 | ✅ 保留 | 命令面板里「使用旧面板 / legacy panel」一键切回 |

**最初的设想现在成立了**：在软件内部访问 AI，AI 能调用软件。

## 二、装与用

```
git clone https://github.com/Athosoo/aseprite-ai-pixel-copilot.git
cd aseprite-ai-pixel-copilot
npm --prefix bridge install
powershell -ExecutionPolicy Bypass -File install.ps1
```

重启 Aseprite，`Ctrl+Shift+A` 开面板。

**关于首次出现的「Security」授权框**（源码 `src/app/script/security.cpp` 第 79-100 行确认）：
key = SHA1(chunkname 去掉一个前导标记字符)，值是该脚本的权限位掩码。
每个脚本文件**首次**调用 io / os / WebSocket 时会问一次，勾上「Don't show this specific alert again」即永久记住。
所以首次使用看到 2~3 个框是正常的，点允许即可 —— **不是 bug**。

## 三、怎么验证

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\verify-v1.0.ps1
```

当前基线：**Lua 1991 通过 / 0 失败**（21 个测试文件）。

真机 GUI 探针（需本机装 Aseprite）：
```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run_gui_v1.ps1 -Mode console -Out tests\lua\gui_v1_console.png
```

## 四、已知问题（诚实清单）

**UI 层**
1. 小窗形态（减号按钮）内容已修好，但只在探针里验过，真机手感待确认。
2. 形态按钮曾被自动化点击误触并把 `bar_side` 持久化进 config；现已加 1.5 秒形态名闪现提示。
   若发现形态不对，把 `bridge/config.json` 的 `ui.mode` 改为 `panel`。
3. 待答提问目前以文本行呈现，还不是独立卡片。
4. 画廊页仍是骨架。

**桥层**
5. `bridge/test/selftest.mjs` 需要 8791 端口上的 mock LLM 服务，缺它会 `ECONNREFUSED`；
   其余 9 个桥测试文件全绿（636 通过），另有 3 条施工前就存在的测试隔离失败未修。

**架构层**
6. 纯 Lua 能力包（不含 bridge 工具）没有完整 verify 路径。
7. 沙箱超时只挡 VM 死循环，挡不住 C 层阻塞（桥侧用子进程硬超时兜）。

## 五、这一版最重要的一条教训

**Aseprite 是开源的，源码就在 `src/` 里。** 本版开发中「面板永不重绘」「require 只在 init 作用域可用」
「Dialog:close 在自身回调里无效」「canvas 鼠标事件语义」「权限键算法」这五件事，全都**读源码十分钟可定论**，
却被我用「改代码 → 跑真机 → 看现象」的方式一轮轮试出来，代价是十几轮返工和用户的时间。

规则：**涉及宿主行为的问题，先读 `src/` 再动手。** 真机验证用于确认，不用于探索。
