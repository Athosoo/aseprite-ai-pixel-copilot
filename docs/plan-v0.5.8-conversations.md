# v0.5.8 计划：对话持久化 + 多对话管理

> 给执行者：这份文档是**结论 + 验收标准**，不是探索记录。动手前先读 `STATUS.md` 顶部和
> `## 关键实现约束`，那里钉着"改回去就会坏"的东西。每个工作项都写了文件、做法、验收方式和
> 测试命令；**先验证再动手**（§0 那几张表就是验证结果）。跑测试都在仓库根目录。

## 0. 先验证：现在到底丢什么、留什么

用户的原话是"记忆和上下文不随窗口和软件关闭而消失，同时实现多对话管理"。先查现状：

| 东西 | 存在哪 | 关面板 | 重启 Aseprite | 重启电脑 |
|---|---|---|---|---|
| 对话上下文（消息 + 摘要） | 桥 `data/history.json`，每轮结束落盘 | 在 | **在**（`selftest` 场景 13 已实证跨桥重启恢复） | 在 |
| 长期记忆（`remember` 那些） | 桥 `data/memory.json` | 在 | 在 | 在 |
| **面板滚回区（屏幕上那些字）** | **Lua 内存 `panel.lines`（上限 800 行）** | 在 | **没了** | 没了 |
| 命令历史（↑/↓） | Lua 内存 | 在 | 没了 | 没了 |
| 多对话 | **不存在**：全桥只有一个 `history.json`，多开 Aseprite 还共用它 | — | — | — |

所以"它忘了"其实是**打开面板看到一片空白**，不是桥真的忘了。另外两个真缺口：

1. **压缩会真删老消息**：`Conversation.compact()` 里 `this.messages = keep` 之后落盘，
   被摘要掉的老消息**从磁盘上消失了**。这是"上下文消失"的第二种形态。
2. 没有"新建 / 切换 / 改名 / 删除"。

**结论**：主线不是"给桥加持久化"（它已经有了），而是
**(a) 把"屏幕上那段记录"也变成落盘的、按对话分文件的东西**，
**(b) 让桥在连上时把该对话回放给面板**，
**(c) 压缩改成"留档"而不是"删除"**，
**(d) 在 (a)(b) 的地基上加多对话管理**。

## 1. 缺口清单（这一轮要做的）

### G1 对话按文件分开存
一个对话 = 一个文件 `bridge/data/conversations/<id>.json`：

```json
{
  "id": "c-20261016-7f3a",
  "title": "把背景改成蓝色",
  "createdAt": "…", "updatedAt": "…",
  "summary": "…最老那段的三句话摘要…",
  "messages": [ "…仍会发给模型的近期原文…" ],
  "archive":  [ "…压缩掉的原始消息，只留档、永不外发…" ],
  "log":      [ { "kind": "user", "text": "把背景改成蓝色" } ]
}
```

- `id` = `c-YYYYMMDD-xxxx`（纯 ASCII，当文件名安全）；`title` 从第一条用户消息派生
  （消息被 `buildUserMessage` 包成 `[Current canvas state]…[User request]…`，要按标记切）。
- **活动对话 id** 落 `config.json` 的 `activeConversation`（和 `activeStyle` 一个套路）。
- 新增 `paths.conversations`（默认 `data/conversations`）。
- → 改：`bridge/src/history.mjs`（`Conversation` 加字段）、新建 `bridge/src/conversations.mjs`。

### G2 压缩留档（摘要 ≠ 删除）
`compact()` 的两个分支都要先 `this.archive.push(...drop)`（上限 2000 条，超了丢最老的），
再 `messages = keep`。留档**永不发给模型**，只保证"原文还在文件里"。

### G3 面板记录（回放行）
- 桥：`Session.say()` 顺手 `history.pushLog(kind, text, i18nKey)`；收到 `chat` 记一行 `user`；
  Lua 发来 `log` 帧时也记（面板本地产的行：切形态、设置保存…）。
- **连接噪声不进记录**：握手那几句（Bridge ready / 没有 API key / gaps 提示 / 上下文已恢复）
  传 `record=false`，否则重连几次记录就被刷满。
- Lua：`Panel:log()` 把本地产的行用 `onLog` 上报（`meta.fromBridge = true` 的行不转发，
  否则同一条会记两遍；`echo` 也不转发 —— 桥自己会记用户那句）。
- 回放上限 400 行（`logCap`），文件里保留更多。

### G4 连上就回放
- `hello` 时桥**先**发 `replay`，再发握手提示 —— 顺序反了的话提示会被回放（清屏重画）冲掉。
- 面板收到 `replay` 就 `clear()` + 逐行按 kind 重画 + 一条表头
  （`── 以下是恢复的记录：N 行 ──`）。**是替换不是追加**：桥是唯一真相来源。
- 带 `i18n` 键的行按当前语言重渲染（重启后换了语言也对）。

### G5 多对话管理（命令表式）
- 协议（`msg.id` 是请求 id，**对话 id 走 `msg.target`**，回复里对话 id 一律叫 `convId`，
  两个都叫 id 太容易串）：
  `conversation_list` → `conversations_result{items,active,dir}`；
  `conversation_new` / `conversation_switch{target}` / `conversation_rename{target,title}` /
  `conversation_delete{target}` → `conversation_result{ok,action,convId,active,count,reason?,next?}`；
  `history_replay` → `replay`；`log{kind,text}`（只记账、不回声）。
- 面板：`会话` / `chats` 列出**对话表**（编号、标题、条数、token，当前那条有标记），
  敲编号切换；表尾三行操作：`n` 新对话、`r` 改名、`d` 删除。
- **复用命令表那套交互**：`Panel:openTable(rows, title, kind)`，`_runMenuIndex` 重打的是
  `self.tableRows` 对应的**当前这张表**（以前写死重打命令表，从对话表里挑一行会把命令表顶上来）。
- 改名 / 删除要参数：`Panel:setPendingInput(action, hint, accept)` —— **下一行输入**当参数。
  故意**不做**"命令 + 空格 + 参数"的前缀匹配：那会把"帮我打开 这张图"这种聊天文本误判成命令。
- **删除 = 移进 `conversations/trash/`**，不是真删；**只剩一个时拒绝删除**
  （否则界面没地方可去）。删当前那个要自动切到另一个，且**切换时不能 save**
  （文件已经移走了，save 会把它原地复活）。
- `reset_history` 语义不变 = "清空当前对话"（保留 id/标题），提示语里点一句"想留旧的请敲 新对话"。
- **不加新工具**（仍是 25 个）：AI 自己不能切对话。系统提示加规则 17c，告诉它这是用户侧命令，
  遇到"开个新对话"要如实指路 —— 否则它会去 `log_gap` 记一条假缺口。

### G6 迁移老用户
`data/conversations/` 为空且 `data/history.json` 有内容 → 建成第一个对话（标题从老消息派生），
原文件改名 `history.json.migrated` 留底。**幂等**（已有对话就不迁）；空的 `history.json` 不迁。

## 2. 执行顺序与验收

1. **存储层**：`history.mjs` 加 `id/title/createdAt/updatedAt/archive/log` + `deriveTitle` /
   `pushLog` / `_archive`；新建 `conversations.mjs`（`ConversationStore`）。
   *验收*：`node test/history_test.mjs`（24 项）、`node test/conversations_test.mjs`（23 项）。
2. **协议层**：`server.mjs` 用 `store.current` 替掉原来的单例（**稳定引用**，切对话只换 `file`
   再 `load()`，所以所有 `history.xxx` 调用点一行都不用改）；记账；`hello` 回放；新消息处理。
   *验收*：`node test/selftest.mjs` 场景 13（改写：读对话文件而不是 history.json）+ 场景 16（新）。
3. **界面层**：`i18n.lua`（内建词 + 文案 + 命令表 `A` 行）、`panel.lua`
   （`openTable` / `setPendingInput` / `replayLines` / `onLog`）、`agent.lua`
   （`showConversationTable` + 三个 `_result` 处理 + `conv:<n>` 转发）。
   *验收*：`panel_test`（242 项）、`artop_test`（103 项）、`gui_agent_probe.lua`（真 GUI 喂 replay）。
4. **全量回归 + 收尾**：Lua 793 + 桥 450 = **1243 项**；升版 0.5.8 → 打包 → 本地安装 →
   提交 → push（SSH）→ Release（附 sha256 校验）。

## 3. 不做的事（明确划掉）

- **不做"每窗口一个对话"**：桥是一个进程（一个端口）服务所有 Aseprite 窗口，活动对话是全局的。
  协议里留了 `hello.conversation` 字段，将来要做得时候不用改结构。写进 README 的已知限制。
- **不做"命令 + 参数"的前缀解析**（见 G5 的理由）。
- **不做对话的导入/导出 UI**：文件就是普通 JSON，用户自己去 `data/conversations/` 拿。
- **不把长期记忆拆成"每对话一份"**：记忆是"助手对你的了解"，换对话也该还在。
- **不做自动新对话**（比如"超预算就自动开一条"）：压缩已经把长对话处理掉了，
  开不开新对话是用户的决定。
- **不做归档的浏览 UI**：`archive` 只是"不丢"，要看得去翻文件。
