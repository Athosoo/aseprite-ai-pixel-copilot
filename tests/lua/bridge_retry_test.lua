-- tests/lua/bridge_retry_test.lua -- 桥连不上：重试、node 解析、端口探测
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/bridge_retry_test.lua
--
-- 这套断言回答一个问题：**桥晚 1~2 秒才起来时，面板会不会自己连上？**
-- 真机上"无法连接桥"就是三件事凑一起：只连一次、node 找不到、已经在跑还再起一个。

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
local function logsMatch(panel, needle)
  for _, l in ipairs(panel.logs) do
    if contains(l.text, needle) then return true end
  end
  return false
end

-- ----------------------------------------------------------------------
-- 假件：面板记录器 / 假 WebSocket / 假定时器
-- ----------------------------------------------------------------------

local function fakePanel()
  local p = { logs = {}, statuses = {} }
  function p:log(text, kind) p.logs[#p.logs + 1] = { text = tostring(text), kind = kind } end
  function p:setStatus(text, kind) p.statuses[#p.statuses + 1] = { text = tostring(text), kind = kind } end
  function p:setBarColor() end
  function p:setMode() end
  function p:layoutMode() return "panel" end
  function p:isShown() return false end
  function p:show() end
  function p:hide() end
  function p:destroy() end
  return p
end

-- 每次 connect 拿一组新 handler；测试用它们模拟"被拒/连上/断开"
local function fakeWs()
  local w = { connects = 0, handlers = nil, lastError = nil }
  w.mod = {
    connect = function(url, handlers)
      w.connects = w.connects + 1
      w.handlers = handlers
      w.url = url
      local open = false
      local conn = {
        isOpen = function() return open end,
        close = function() open = false end,
        send = function() return true end,
      }
      w.conn = conn
      w.open = function() open = true; handlers.onOpen() end
      w.fail = function(msg) w.lastError = msg or "connection refused"; handlers.onError(w.lastError) end
      w.disconnect = function() open = false; handlers.onClose() end
      return conn
    end,
  }
  return w
end

local function fakeTimers()
  local t = { queue = {}, cancelled = 0, scheduled = 0 }
  function t.after(seconds, fn)
    local h = { seconds = seconds, fn = fn, stopped = false }
    function h:stop() self.stopped = true end
    t.queue[#t.queue + 1] = h
    t.scheduled = t.scheduled + 1
    return h
  end
  function t.cancel(h) t.cancelled = t.cancelled + 1; if h and h.stop then h:stop() end end
  function t.pending()
    local n = 0
    for _, h in ipairs(t.queue) do if not h.stopped then n = n + 1 end end
    return n
  end
  function t.fireNext()
    for i, h in ipairs(t.queue) do
      if not h.stopped then table.remove(t.queue, i); h.fn(); return true end
    end
    return false
  end
  return t
end

local function newAgent(opts)
  opts = opts or {}
  local timers = fakeTimers()
  local w = fakeWs()
  local a = agent.new{
    port = 8777,
    bridgeHint = "node bridge/src/server.mjs",
    connectRetry = { delay = 1, max = opts.max or 3 },
    after = timers.after,
    cancelTimer = timers.cancel,
    ws = w.mod,
  }
  local panel = fakePanel()
  a.panel = panel
  return a, w, timers, panel
end

-- ----------------------------------------------------------------------
print("== 1. 连接重试：桥晚起来时自己接上 ==")
do
  local a, w, timers, panel = newAgent()
  a:connect(true)
  eq(w.connects, 1, "connect 先试一次")
  eq(timers.pending(), 0, "还没失败，不排重试")

  w.fail("connection refused")
  eq(timers.pending(), 1, "被拒之后排了一次重试")

  timers.fireNext()
  eq(w.connects, 2, "重试真的又连了一次")

  w.open()
  eq(w.connects, 2, "连上之后不再多连")
  eq(timers.pending(), 0, "连上即停：没有排队中的重试")
  eq(a._retrying, false, "连上后不再处于重试状态")
  local lastStatus = panel.statuses[#panel.statuses]
  eq(lastStatus and lastStatus.kind, "ok", "状态改成了 ok（已连接）")

  a:connect(true)
  eq(w.connects, 2, "已连上时再调 connect 不会新建连接")
  a:destroy()
end

print("== 2. 全部失败：可读结论 + 手动重试入口 ==")
do
  local a, w, timers, panel = newAgent({ max = 3 })
  a:connect(true)
  w.fail()
  timers.fireNext()
  w.fail()
  timers.fireNext()
  w.fail()

  eq(w.connects, 3, "max=3 就只试 3 次，不多打")
  eq(timers.pending(), 0, "全部失败后不再排队")
  eq(a._retrying, false, "重试状态收尾")
  ok(logsMatch(panel, "3 次尝试都没连上桥"), "给出可读结论（次数 + 地址）",
    panel.logs[#panel.logs] and panel.logs[#panel.logs].text)
  ok(logsMatch(panel, "重连"), "指出手动重试入口（命令表里的「重连」）")
  ok(logsMatch(panel, "手动起桥"), "给出手动起桥命令")
  local lastStatus = panel.statuses[#panel.statuses]
  eq(lastStatus and lastStatus.kind, "error", "状态停在 error")
  a:destroy()
end

print("== 3. 取消与单飞 ==")
do
  local a, w, timers, panel = newAgent()
  a:connect(true)
  w.fail()
  eq(timers.pending(), 1, "先排上一次")

  a:cancelRetry()
  eq(timers.pending(), 0, "cancelRetry 清掉排队中的重试")
  local before = w.connects
  timers.fireNext()
  eq(w.connects, before, "被取消的回调不再触发连接")
  a:destroy()

  local a2, w2, timers2 = newAgent()
  a2:connect(true)
  w2.fail()
  w2.disconnect()          -- onError 与 onClose 都来
  eq(timers2.pending(), 1, "onError+onClose 同时来也只排一次")
  a2:destroy()

  local a3, w3, timers3 = newAgent()
  a3:connect(true)
  w3.fail()
  local stale = w3.handlers     -- 老连接的 handler
  timers3.fireNext()            -- 进入第 2 次尝试
  local connectsBefore = w3.connects
  stale.onError("late failure from an old socket")
  eq(timers3.pending(), 0, "旧连接的迟到回调不会再排队")
  eq(w3.connects, connectsBefore, "旧连接的迟到回调不会多连一次")
  a3:destroy()

  local a4, w4, timers4 = newAgent()
  a4:connect(true)
  w4.fail()
  eq(timers4.pending(), 1, "destroy 之前有一个排队的重试")
  a4:destroy()
  eq(timers4.pending(), 0, "destroy 会把定时器清掉")
end

-- ----------------------------------------------------------------------
print("== 4. main.lua：node 解析 ==")
do
  local chunk = assert(loadfile(EXT .. "/main.lua"))
  chunk()
  ok(type(resolveNode) == "function" and type(portInUse) == "function" and type(startBridge) == "function",
    "main.lua 导出 resolveNode / portInUse / startBridge")

  local function deps(env, existing)
    return {
      env = function(k) return env[k] end,
      exists = function(p) return existing[p] == true end,
    }
  end

  local pathHit = resolveNode(deps({ PATH = "C:\\nowhere;C:\\tools" }, { ["C:\\tools\\node.exe"] = true }))
  ok(pathHit ~= nil and contains(pathHit, "tools"), "PATH 里的 node 能被找到", pathHit)

  local pfHit = resolveNode(deps({ PATH = "", ProgramFiles = "C:\\Program Files" },
    { ["C:\\Program Files\\nodejs\\node.exe"] = true }))
  ok(pfHit ~= nil and contains(pfHit, "Program Files"), "ProgramFiles\\nodejs 能被找到", pfHit)

  local ladHit = resolveNode(deps({ PATH = "", LOCALAPPDATA = "C:\\Users\\u\\AppData\\Local" },
    { ["C:\\Users\\u\\AppData\\Local\\Programs\\nodejs\\node.exe"] = true }))
  ok(ladHit ~= nil and contains(ladHit, "Programs"), "LOCALAPPDATA\\Programs\\nodejs 能被找到", ladHit)

  local none, noneErr, tried = resolveNode(deps({ PATH = "C:\\a" }, {}))
  ok(none == nil, "都找不到时返回 nil")
  ok(contains(noneErr, "找不到 node"), "错误文本说清是 node 找不到", noneErr)
  ok(type(tried) == "table" and #tried > 0, "把试过的路径一起带出来（便于排查）", type(tried) == "table" and #tried)

  local trailing = resolveNode(deps({ PATH = "C:\\tools\\" }, { ["C:\\tools\\node.exe"] = true }))
  ok(trailing ~= nil, "PATH 尾部带反斜杠也能拼对", trailing)
end

print("== 5. main.lua：端口探测 ==")
do
  local listening = "  TCP    127.0.0.1:8777    0.0.0.0:0    LISTENING    1234"
  local busy, detail = portInUse(8777, { output = listening })
  eq(busy, true, "LISTENING 行 → 端口已在用")
  ok(contains(detail, "8777"), "带上端口号便于排查", detail)

  local wait = "  TCP    127.0.0.1:8777    127.0.0.1:50000    TIME_WAIT    0"
  eq(portInUse(8777, { output = wait }), false, "TIME_WAIT 不算有桥在听")
  eq(portInUse(8777, { output = "" }), false, "空输出 → 没在用")

  -- 走真实文件路径（生产用的就是这条）：run 写一个假的 netstat 输出
  local dir = (os.getenv("TEMP") or ".") .. "/ai-pixel-copilot-test-port-" .. tostring(os.time())
  pcall(function() app.fs.makeAllDirectories(dir) end)
  local tmp = dir .. "/netstat.txt"
  local realBusy = portInUse(8777, {
    tmpPath = tmp,
    run = function(cmd)
      local f = assert(io.open(tmp, "wb"))
      f:write(listening)
      f:close()
    end,
  })
  eq(realBusy, true, "从 netstat 输出文件里读出 LISTENING")

  local thrown = portInUse(8777, { run = function() error("netstat missing") end })
  eq(thrown, false, "netstat 执行失败时不崩、当作端口空闲")
end

print("== 6. main.lua：startBridge 三条路 ==")
do
  local already, alreadyDetail = startBridge({ portBusy = true })
  eq(already, "already", "端口已有桥 → 跳过启动")
  ok(contains(alreadyDetail, "已有桥"), "说明为什么跳过", alreadyDetail)

  local ran = nil
  local started, startedDetail = startBridge({
    entry = "C:\\repo\\bridge\\dist\\bridge.mjs",
    portBusy = false,
    env = function(k) if k == "PATH" then return "C:\\tools" end return nil end,
    exists = function(p) return p == "C:\\tools\\node.exe" end,
    run = function(cmd) ran = cmd end,
  })
  eq(started, "started", "找到 node 就拉起")
  ok(ran ~= nil and contains(ran, "node.exe"), "命令里用的是解析到的绝对 node 路径", ran)
  ok(ran ~= nil and contains(ran, "bridge.mjs"), "命令里带桥入口", ran)
  ok(contains(startedDetail, "已拉起"), "回报里说明用的是哪个 node", startedDetail)

  local failed, failedDetail = startBridge({
    entry = "C:\\repo\\bridge\\dist\\bridge.mjs",
    portBusy = false,
    env = function() return "" end,
    exists = function() return false end,
    run = function() error("should not run") end,
  })
  eq(failed, "failed", "找不到 node 就失败")
  ok(contains(failedDetail, "找不到 node"), "失败原因写清是 node 找不到", failedDetail)
  ok(contains(failedDetail, "Node.js"), "并告诉用户该装什么", failedDetail)
end

print("== 7. 谁负责发起连接（工作台不连 = 没人连）==")
do
  ok(type(connectIfNeeded) == "function", "main.lua 导出 connectIfNeeded")

  local calls = 0
  local fake = { connect = function() calls = calls + 1 end }
  eq(connectIfNeeded(fake, "legacy"), false, "legacy：不在入口里连（旧面板 a:open() 自己会连）")
  eq(calls, 0, "legacy 下没有多连一次")

  eq(connectIfNeeded(fake, "workbench"), true, "workbench：由入口发起连接")
  eq(calls, 1, "workbench 下真的调了一次 connect")

  eq(connectIfNeeded(nil, "workbench"), false, "没有 agent 时不崩")
  eq(connectIfNeeded({}, "workbench"), false, "agent 没有 connect 方法时不崩")
end

-- 清理临时文件
pcall(function()
  os.remove((os.getenv("TEMP") or ".") .. "/ai-pixel-copilot-test-port-" .. tostring(os.time()) .. "/netstat.txt")
end)

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error(fail .. " 个断言失败") end
