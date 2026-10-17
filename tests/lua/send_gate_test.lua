-- tests/lua/send_gate_test.lua -- 未连接时发送不许抛错（真机 ws.lua:125 那个 bug）
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/send_gate_test.lua
--
-- 红证明在 §1：绕过闸门直发会**真的**复现真机那行抛错；闸门在 §2 起把它变成"排队"。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local agent = require("lib.agent")

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
local function eq(a, b, name)
  ok(a == b, name, string.format("got %s want %s", tostring(a), tostring(b)))
end
local function contains(text, needle)
  return tostring(text):find(needle, 1, true) ~= nil
end

-- ws.lua:125 的原文（照抄真机日志）
local NOT_CONNECTED = "WebSocket is not connected, can't send text"

local function fakePanel()
  local p = { logs = {}, statuses = {} }
  function p:log(t, k) p.logs[#p.logs + 1] = { text = tostring(t), kind = k } end
  function p:setStatus(t, k) p.statuses[#p.statuses + 1] = { text = tostring(t), kind = k } end
  function p:setBarColor() end
  function p:setMode() end
  function p:layoutMode() return "panel" end
  function p:isShown() return false end
  function p:show() end
  function p:hide() end
  function p:destroy() end
  return p
end

-- 假连接：open 之前 send/sendBinary 抛和 ws.lua 一样的错（这就是真机的行为）
local function fakeConn()
  local c = { open = false, sent = {}, binSent = {} }
  function c:isOpen() return c.open end
  function c:send(tbl)
    if not c.open then error(NOT_CONNECTED, 0) end
    c.sent[#c.sent + 1] = tbl
    return true
  end
  function c:sendBinary(header, data)
    if not c.open then error(NOT_CONNECTED, 0) end
    c.binSent[#c.binSent + 1] = { header = header, data = data }
    return true
  end
  function c:close() c.open = false end
  return c
end

local function newAgent()
  local a = agent.new{ port = 8777, bridgeHint = "node bridge/src/server.mjs" }
  a.panel = fakePanel()
  a.conn = fakeConn()
  return a, a.conn, a.panel
end

local function logHas(panel, needle)
  for _, l in ipairs(panel.logs) do if contains(l.text, needle) then return true end end
  return false
end

-- ----------------------------------------------------------------------
print("== 1. 红证明：绕过闸门直发，真的会抛 ws.lua:125 ==")
do
  local a, conn = newAgent()
  local okDirect, directErr = pcall(function() conn:send({ type = "set_config", llm = { model = "x" } }) end)
  ok(okDirect == false, "直发在未连接时抛错（这就是真机那行红字）")
  ok(contains(directErr, NOT_CONNECTED), "错误文本就是 ws.lua:125 那句", directErr)
  eq(#conn.sent, 0, "抛错时没有任何帧发出去")
  a:destroy()
end

print("== 2. 闸门：未连接时不抛，控制帧排队 ==")
do
  local a, conn, panel = newAgent()
  local threw = false
  local sentOk
  local okCall, err = pcall(function()
    sentOk = a:send{ type = "set_config", llm = { model = "deepseek-chat" } }
  end)
  threw = not okCall
  ok(threw == false, "未连接时 self:send 不抛（闸门兜住）", err)
  eq(sentOk, false, "回报 false（表示没真发出去）")
  eq(#conn.sent, 0, "未连接时一个帧都没发")
  eq(#a._pendingSend, 1, "控制帧进了待发队列")
  eq(a._pendingSend[1].tbl.type, "set_config", "队列里是那条 set_config")

  a:send{ type = "log", kind = "info", text = "noise" }
  eq(#a._pendingSend, 1, "log 帧不入队（没有重放价值）")
  eq(a._droppedLogs, 1, "log 帧被丢弃并计数")
  a:destroy()
end

print("== 3. 连上后按 hello -> 控制帧 -> 聊天 的顺序补发 ==")
do
  local a, conn, panel = newAgent()
  a:send{ type = "set_config", ui = { mode = "panel" } }
  a:send{ type = "set_config", llm = { thinking = true } }
  a.pendingChats = { "先打的这句" }
  eq(#a._pendingSend, 2, "两条控制帧在排队")

  conn.open = true
  -- 模拟 onOpen 的顺序：hello 先发，然后 _flushControl，再 flushPendingChats
  a:send{ type = "hello", aseprite = "1.3.18.6-dev" }
  eq(a:_flushControl(), 2, "补发了 2 条控制帧")
  a:flushPendingChats()

  eq(#a._pendingSend, 0, "补发完队列清空")
  eq(#conn.sent, 4, "发出 4 帧：hello + 2 控制 + 1 聊天")
  eq(conn.sent[1].type, "hello", "第 1 帧是 hello")
  eq(conn.sent[2].type, "set_config", "第 2 帧是积压的控制帧（先入先出）")
  eq(conn.sent[3].type, "set_config", "第 3 帧是第二条控制帧")
  eq(conn.sent[4].type, "chat", "第 4 帧才是聊天")
  ok(logHas(panel, "已补发离线期间积压的 2 条消息"), "补发有可读日志", panel.logs[#panel.logs] and panel.logs[#panel.logs].text)
  a:destroy()
end

print("== 4. 二进制帧也过闸门 ==")
do
  local a, conn = newAgent()
  local okCall, err = pcall(function()
    a:_safeSendBinary({ type = "canvas_pixels", id = 7, width = 8, height = 8 }, "rgba-bytes")
  end)
  ok(okCall == true, "未连接时发二进制不抛", err)
  eq(#conn.binSent, 0, "未连接时没真发")
  eq(#a._pendingSend, 1, "二进制帧进队列")
  eq(a._pendingSend[1].kind, "binary", "队列项标记为 binary")

  conn.open = true
  eq(a:_flushControl(), 1, "连上后补发二进制帧")
  eq(#conn.binSent, 1, "二进制真的发出去了")
  eq(conn.binSent[1].header.type, "canvas_pixels", "头部原样")
  eq(conn.binSent[1].data, "rgba-bytes", "像素数据原样")
  a:destroy()
end

print("== 5. 真错误照旧显示，'未连接发送'不再刷红 ==")
do
  local a, conn, panel = newAgent()
  a:send{ type = "set_config", ui = {} }        -- 未连接：不该出现 error
  local hasError = false
  for _, l in ipairs(panel.logs) do if l.kind == "error" then hasError = true end end
  eq(hasError, false, "未连接时发送不产生 error 级日志")

  conn.open = true
  local okSend = a:send{ type = "set_config", ui = {} }
  eq(okSend, true, "连上后同一帧直接发出")
  eq(#a._pendingSend, 1, "队列里仍留着离线那条（等下次 flush）")
  a:destroy()
end

print("== 6. 队列有上限，离线久了不无限堆 ==")
do
  local a, conn = newAgent()
  for i = 1, 50 do a:send{ type = "set_config", ui = { n = i } } end
  ok(#a._pendingSend <= 32, "队列长度被上限截住", #a._pendingSend)
  eq(a._pendingSend[#a._pendingSend].tbl.ui.n, 50, "留下的是最新的那条")
  a:destroy()
  eq(a._pendingSend, nil, "destroy 清掉积压，不跨会话残留")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error(fail .. " 个断言失败") end
