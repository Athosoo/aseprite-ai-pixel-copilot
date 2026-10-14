-- tests/lua/gui_ws_probe.lua
--
-- 用途：验证 GUI 模式下 Lua 的 WebSocket 回调能正常收发。
-- 无头（-b）模式下回调不会触发（回调走 os::queue_event，批处理没有事件循环），
-- 所以这一环只能用 GUI 实例测。
--
-- 跑法（会短暂弹出一个 Aseprite 窗口，测完自动退出）：
--   1) 先起 echo 服务： node bridge/test/echo.mjs
--   2) 在仓库根跑： aseprite.exe --script tests/lua/gui_ws_probe.lua
-- 结果写到 tests/lua/gui_ws_result.txt

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end   -- 从仓库根跑即可

local OUT = ROOT .. "/tests/lua/gui_ws_result.txt"
local log = {}
local function w(s)
  log[#log + 1] = tostring(s)
end
local function flush()
  local f = io.open(OUT, "w")
  if f then
    f:write(table.concat(log, "\n") .. "\n")
    f:close()
  end
end

w("start  gui=" .. tostring(app.isUIAvailable) .. "  version=" .. tostring(app.version))

local queue = {}
local sock = WebSocket{
  url = "ws://127.0.0.1:8799",
  onreceive = function(msgType, data, err)
    queue[#queue + 1] = { t = msgType, d = data, e = err }
  end,
}
sock:connect()
w("connect() 已调用")

local tries = 0
local sentHello = false
local timer = Timer{
  interval = 0.1,
  ontick = function()
    tries = tries + 1

    while #queue > 0 do
      local m = table.remove(queue, 1)
      w("回调: type=" .. tostring(m.t) .. "  data=" .. tostring(m.d):sub(1, 80))

      if m.t == WebSocketMessageType.OPEN and not sentHello then
        sentHello = true
        sock:sendText("hello-from-aseprite")
        w("已发送文本帧")
      elseif m.t == WebSocketMessageType.TEXT then
        w("收到回显: " .. tostring(m.d))
        w("RESULT=OK")
        timer:stop()
        flush()
        app.exit()
        return
      end
    end

    if tries > 60 then
      w("RESULT=FAIL 超时 6 秒，未完成收发")
      timer:stop()
      flush()
      app.exit()
    end
  end,
}
timer:start()
w("timer 已启动，等待回调…")
