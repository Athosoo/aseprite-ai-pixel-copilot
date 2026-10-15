-- tests/lua/artop_test.lua -- 协议层：桥发来的消息 -> Lua 真的动了画布
--
-- 跑法： 在仓库根执行
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/artop_test.lua
--
-- artlib_test.lua 测的是"函数调对了没有"，这一层测的是"**字段名对不对**"：
-- 桥发的 {layer, palette, rows, x, y} 和 agent.lua 读的 msg.xxx 一旦对不上，
-- 函数单测全绿也没用 —— 而且这种错只有真跑一遍协议才暴露得出来。
--
-- 做法：构造真的 Agent，把 send / panel 换成假的，然后喂协议消息进去。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local agent = require("lib.agent")
local i18n = require("lib.i18n")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end

local a = agent.new{ port = 1 }

-- 收集发出去的帧 + 面板日志（别真往对话框里写）
local sent, logs = {}, {}
local statuses = {}
a.send = function(_, msg) sent[#sent + 1] = msg end
local modeCalls = {}
a.panel = {
  log = function(_, text, kind) logs[#logs + 1] = { text = text, kind = kind } end,
  setStatus = function(_, text, kind, doc)
    statuses[#statuses + 1] = { text = text, kind = kind, doc = doc }
  end,
  setMode = function(_, mode, quiet) modeCalls[#modeCalls + 1] = { mode = mode, quiet = quiet } end,
  setBarColor = function(_, c) modeCalls[#modeCalls + 1] = { barBg = c } end,
  layoutMode = function() return "panel" end,
}

-- 喂一条消息，返回它发出的第一帧
local function feed(msg)
  sent, logs = {}, {}
  a:onMessage(msg)
  return sent[1]
end

-- 取当前文档里某个图层的 cel
local function celOf(spr, name)
  for _, l in ipairs(spr.layers) do
    if l.name == name then return l:cel(1) end
  end
end

print("== new_sprite ==")
do
  local r = feed{ type = "new_sprite", id = 1, width = 16, height = 24, colorMode = "rgb" }
  ok(r ~= nil, "回了帧")
  ok(r.type == "art_result", "帧类型 = art_result，实际 " .. tostring(r and r.type))
  ok(r.id == 1, "id 原样回传")
  ok(r.ok == true, "成功")
  ok(r.report.size == "16x24", "报告尺寸 16x24，实际 " .. tostring(r.report and r.report.size))
  ok(app.activeSprite.width == 16 and app.activeSprite.height == 24, "真的开了 16x24 的文档")
  ok(r.report.op == "new_sprite", "op 标成 new_sprite")
end

print("== new_sprite: 参数不合法 -> 失败但不出错 ==")
do
  local r = feed{ type = "new_sprite", id = 2, width = 0, height = 10 }
  ok(r.ok == false, "拒绝了 0 宽")
  ok(type(r.error) == "string" and r.error:find("at least 1") ~= nil, "错误信息说清了原因", r.error)
  ok(app.activeSprite.width == 16, "画布没被破坏")
end

print("== add_layer ==")
do
  local before = #app.activeSprite.layers
  local r = feed{ type = "add_layer", id = 3, name = "高光", opacity = 128 }
  ok(r.type == "art_result" and r.ok == true, "成功")
  ok(#app.activeSprite.layers == before + 1, "图层数 +1")
  ok(r.report.layer == "高光", "图层名转发正确（msg.name -> report.layer），实际 " .. tostring(r.report and r.report.layer))
  ok(r.report.opacity == 128, "不透明度转发正确（msg.opacity），实际 " .. tostring(r.report and r.report.opacity))
end

print("== draw_art：字段名要对得上 ==")
do
  local r = feed{
    type = "draw_art", id = 4,
    label = "画个方块",
    layer = "主体",                      -- 桥发的是 layer，不是 layerName
    palette = { ["."] = "", X = "#2E86DE" },  -- 桥发的是 palette
    rows = { "..XX..", ".XXXX.", "XXXXXX" },  -- 桥发的是 rows
    x = 2, y = 3,                        -- 桥发的是 x / y
  }
  ok(r.type == "art_result" and r.ok == true, "成功")
  ok(r.report.op == "draw_art", "op 标成 draw_art")
  ok(r.report.layer == "主体", "落到指定图层，实际 " .. tostring(r.report and r.report.layer))
  ok(r.report.painted == 12, "画了 12 个像素（2+4+6），实际 " .. tostring(r.report and r.report.painted))
  ok(r.report.width == 6 and r.report.height == 3, "网格尺寸对")
  ok(r.report.changed == true, "changed 标了 true")

  local cel = celOf(app.activeSprite, "主体")
  ok(cel ~= nil, "图层 主体 存在（不存在时被自动建出来）")
  if cel then
    -- rows[1] = "..XX.." -> 两个 X 落在 rx=3,4；x=2 偏移后是画布 x=4,5
    ok(cel.image:getPixel(4, 3) ~= 0, "(4,3) 画上了 —— x/y 偏移生效")
    ok(cel.image:getPixel(0, 0) == 0, "(0,0) 没被碰")
    ok(cel.image:getPixel(7, 5) ~= 0, "(7,5) 画上了 —— rows 顺序没反")
  end
end

print("== draw_art：行宽写歪 -> 失败，画布不动 ==")
do
  local r = feed{
    type = "draw_art", id = 5, layer = "主体",
    palette = { X = "#FF0000" },
    rows = { "XXX", "XX" },
  }
  ok(r.ok == false, "拒绝了行宽不一致的网格")
  ok(type(r.error) == "string" and r.error:find("same width") ~= nil, "错误信息指出是行宽问题", r.error)
  local cel = celOf(app.activeSprite, "主体")
  ok(cel and cel.image:getPixel(4, 3) ~= 0, "之前画的内容还在（没有半张错图）")
end

print("== draw_art：出界像素跳过并计数 ==")
do
  -- 16x24 的画布，把 3x3 实心块放在 (15,23)：只有右下角那 1 个在界内
  local r = feed{
    type = "draw_art", id = 6, layer = "边界",
    palette = { X = "#00FF00" },
    rows = { "XXX", "XXX", "XXX" },
    x = 15, y = 23,
  }
  ok(r.ok == true, "成功（出界不算错误）")
  ok(r.report.painted == 1, "只画进去 1 个，实际 " .. tostring(r.report.painted))
  ok(r.report.skippedOutOfBounds == 8, "报告跳过 8 个，实际 " .. tostring(r.report.skippedOutOfBounds))
  ok(#logs >= 2 and logs[#logs].text:find("画布外") ~= nil, "面板另外提示了有像素落在画布外")
end

print("== crop / scale / canvas_size 走 size_result ==")
do
  local r = feed{ type = "crop", id = 7, label = "裁一下", x = 0, y = 0, w = 8, h = 8 }
  ok(r.type == "size_result", "crop 回 size_result，实际 " .. tostring(r and r.type))
  ok(r.ok == true, "crop 成功")
  ok(app.activeSprite.width == 8 and app.activeSprite.height == 8, "画布裁到 8x8")

  local r2 = feed{ type = "scale", id = 8, width = 4, height = 4, method = "nearest" }
  ok(r2.type == "size_result" and r2.ok == true, "scale 成功")
  ok(app.activeSprite.width == 4, "画布缩到 4")

  local r3 = feed{ type = "canvas_size", id = 9, width = 10, height = 10, anchor = "center" }
  ok(r3.type == "size_result" and r3.ok == true, "canvas_size 成功")
  ok(app.activeSprite.width == 10, "画布改成 10")
end

print("== P3 中断：命令 -> 发出 abort 帧 ==")
do
  -- 连上之后才发得出去（未连接时只提示）
  a.conn = { isOpen = function() return true end }
  sent, logs = {}, {}
  a:action("abort")
  ok(#sent == 1 and sent[1].type == "abort", "action('abort') 发出了 abort 帧，实际 " ..
    tostring(sent[1] and sent[1].type))
  ok(#logs == 1 and logs[1].text == i18n.t("abortSent"), "面板回显了「已发出中断请求」")

  -- 没连上时别静默失败
  a.conn = nil
  sent, logs = {}, {}
  a:abort()
  ok(#sent == 0, "未连接时不发帧")
  ok(#logs == 1 and logs[1].text == i18n.t("abortNothing"), "未连接时给出提示")
  a.conn = nil
end

print("== P2/P5a 状态帧：kind 和当前文件名都要转发 ==")
do
  statuses = {}
  a:onMessage{ type = "status", text = "running crop...", kind = "tool" }
  ok(#statuses == 1, "状态被转给面板")
  ok(statuses[1].text == "running crop...", "文本原样转发")
  ok(statuses[1].kind == "tool", "kind 原样转发（决定状态栏配色），实际 " .. tostring(statuses[1].kind))
  ok(type(statuses[1].doc) == "string" and statuses[1].doc ~= "",
    "带上了当前文档名（P5a），实际 " .. tostring(statuses[1].doc))
end

print("== P7 选项式提问：双通道 + 防重 ==")
do
  -- panel 换成真的？不用：只断言发出去的帧和面板收到的调用
  local asks = {}
  a.panel.setAsk = function(_, ask, silent) asks[#asks + 1] = { ask = ask, silent = silent } end
  a.panel._showAskDialog = function() end
  a.panel._closeAskDialog = function() end
  a.conn = { isOpen = function() return true end }

  sent, logs, asks = {}, {}, {}
  a:onMessage{ type = "ask", id = 77, question = "覆盖原图还是保留副本？",
               options = { "覆盖原图", "保留副本" } }
  ok(#sent == 0, "刚收到提问时不立刻回答")
  ok(a.pendingAskId == 77, "记下了待答 id，实际 " .. tostring(a.pendingAskId))
  ok(#asks == 1 and asks[1].ask.question == "覆盖原图还是保留副本？", "问题转给了面板")

  -- 通道 1：终端敲数字
  a:answerAsk(2)
  ok(#sent == 1 and sent[1].type == "answer", "回了 answer 帧，实际 " ..
    tostring(sent[1] and sent[1].type))
  ok(sent[1].id == 77, "id 原样回传")
  ok(sent[1].index == 2 and sent[1].choice == "保留副本", "选项内容和下标都对，实际 " ..
    tostring(sent[1].choice))
  ok(a.pendingAskId == nil, "答完清掉待答状态")
  ok(#logs >= 1 and logs[#logs].text == string.format(i18n.t("askAnswered"), "保留副本"),
    "面板回显了选择")

  -- 通道 2：取消（关窗 / 敲 x）
  sent, logs, asks = {}, {}, {}
  a:onMessage{ type = "ask", id = 78, question = "继续吗？", options = { "继续", "算了" } }
  a:answerAsk("cancel")
  ok(#sent == 1 and sent[1].cancelled == true, "取消回的是 cancelled 帧")
  ok(sent[1].id == 78, "取消也带 id")
  ok(#logs >= 1 and logs[#logs].text == i18n.t("askCancelled"), "面板提示已取消")

  -- 防重：连来两个 ask，第一个必须被自动取消，否则桥要等到 5 分钟超时
  sent, logs, asks = {}, {}, {}
  a:onMessage{ type = "ask", id = 79, question = "第一个？", options = { "A", "B" } }
  a:onMessage{ type = "ask", id = 80, question = "第二个？", options = { "C", "D" } }
  ok(#sent == 1 and sent[1].id == 79 and sent[1].cancelled == true,
    "第一个提问被自动取消，实际 " .. tostring(sent[1] and sent[1].id))
  ok(a.pendingAskId == 80, "现在等的是第二个")
  a:answerAsk(1)
  ok(sent[2].id == 80 and sent[2].choice == "C", "第二个正常回答")

  -- 没有待答问题时回答 -> 什么都不发
  sent = {}
  a:answerAsk(1)
  ok(#sent == 0, "没有待答问题时回答不发帧")
  a.conn = nil
end

print("== G3/G5 config 消息里的形态和底色要恢复 ==")
do
  modeCalls = {}
  a:onMessage{ type = "config", llm = {}, ui = { mode = "bar_side", barBg = "#2B2B2B" },
               workspace = { root = "" } }
  local gotSide, gotColor = false, nil
  for _, c in ipairs(modeCalls) do
    if c.mode == "bar_side" then gotSide = true end
    if c.barBg then gotColor = c.barBg end
  end
  ok(gotSide, "按 config 恢复成侧边栏")
  ok(gotColor == "#2B2B2B", "按 config 恢复栏底色，实际 " .. tostring(gotColor))
  ok(modeCalls[1].quiet == true, "启动恢复时不要刷日志（quiet）")
end

print("== 未知消息类型不炸 ==")
do
  local r = feed{ type = "definitely_not_a_real_message", id = 10 }
  ok(r == nil, "没回帧")
  ok(#logs == 1 and logs[1].kind == "error", "面板报了一条错")
end

print(string.format("%d passed, %d failed", pass, fail))
