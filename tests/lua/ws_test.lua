-- tests/lua/ws_test.lua -- 二进制帧协议（头帧 + 负载）的形状
--
-- 跑法：在仓库根执行
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/ws_test.lua
--
-- 为什么单独有这个文件（v0.5.9）：
--   桥和 Lua 靠"头帧 + 二进制帧"传图片。这个协议**没有类型检查**，两边写歪了
--   在单测里看不出来 —— 当时 Lua 侧把语义 type 覆盖成 "binary_header"，
--   桥没有这个分支，于是上传和 get_canvas 两条路**全死**，一路挂到超时，
--   而所有测试都是绿的（mock Aseprite 用的是桥那边的写法，不是真客户端的写法）。
--   这里就用假 socket 钉住"真客户端发出去的帧长什么样"，再钉住"收到头帧会存起来等负载"。
--
-- 无头模式也能跑：Conn 的收发逻辑不依赖真 socket（下面直接把 socket 换成假的）。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local ws = require("lib.ws")

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

-- 造一个 Conn：connect 连不上也无所谓，下面全部用假 socket
local received = {}
local conn = ws.connect("ws://127.0.0.1:9", {
  onText = function(msg) received[#received + 1] = { kind = "text", msg = msg } end,
  onBinary = function(header, data)
    received[#received + 1] = { kind = "binary", header = header, data = data }
  end,
})

local sentText, sentBin = {}, {}
conn.socket = {
  sendText = function(_, t) sentText[#sentText + 1] = t end,
  sendBinary = function(_, d) sentBin[#sentBin + 1] = d end,
}

print("== 发出去的头帧：type 必须保留，只用 binary 标出后面跟着负载 ==")
do
  local header = { type = "canvas_pixels", id = 42, width = 2, height = 2 }
  local okSend = conn:sendBinary(header, "ABCD")
  ok(okSend == true, "sendBinary 返回 true")
  ok(#sentText == 1 and #sentBin == 1, "发了一帧文本 + 一帧二进制")

  local decoded = json.decode(sentText[1])
  ok(decoded.type == "canvas_pixels", "type 原样保留（桥靠它分派），实际 " .. tostring(decoded.type))
  ok(decoded.type ~= "binary_header", "不能是 binary_header —— 桥没有这个分支，会被丢掉")
  ok(decoded.binary == true, "带 binary=true 标记")
  ok(decoded.id == 42 and decoded.width == 2 and decoded.height == 2, "其它字段一个不少")
  ok(sentBin[1] == "ABCD", "负载原样发出去")

  -- 调用方那张表不该被改动（以前是就地改 type，外面复用会出怪事）
  ok(header.binary == nil and header.type == "canvas_pixels", "不改调用方的表")
end

print("== 收到的头帧：binary=true 的存起来等负载，其它照常当消息 ==")
do
  received = {}
  local T = WebSocketMessageType
  conn:_receive(T.TEXT, json.encode({ type = "import_image", width = 2, height = 2, note = "n", binary = true }))
  ok(#received == 0, "头帧不当普通消息派发")
  ok(conn.pendingBinaryHeader ~= nil, "头帧存进了 pendingBinaryHeader")

  conn:_receive(T.BINARY, "WXYZ")
  ok(#received == 1 and received[1].kind == "binary", "负载派发给了 onBinary")
  ok(received[1].header and received[1].header.type == "import_image",
    "配对上了那个头帧，type = " .. tostring(received[1].header and received[1].header.type))
  ok(received[1].header.note == "n", "头帧的 note 也在")
  ok(received[1].data == "WXYZ", "负载内容对")
  ok(conn.pendingBinaryHeader == nil, "配完就清掉（不会串到下一帧）")

  -- 普通消息照常走 onText
  received = {}
  conn:_receive(T.TEXT, json.encode({ type = "say", kind = "ai", text = "hi" }))
  ok(#received == 1 and received[1].kind == "text" and received[1].msg.type == "say", "普通消息照常派发")

  -- 老写法的兼容：type = binary_header 也认（万一对方是旧版）
  received = {}
  conn:_receive(T.TEXT, json.encode({ type = "binary_header", width = 1, height = 1 }))
  ok(conn.pendingBinaryHeader ~= nil and #received == 0, "老写法 binary_header 也当头部")
  conn.pendingBinaryHeader = nil

  -- 没有头帧就来负载：不能炸
  received = {}
  conn:_receive(T.BINARY, "orphan")
  ok(#received == 1 and received[1].header ~= nil, "孤立负载也给一个（空）头，不炸")
end

print("== 面板里那两条路都用同一个形状（上传 / 当前画布）==")
do
  -- Agent:upload / Agent:sendCanvas 都走 conn:sendBinary；这里只钉形状，
  -- 真正的取像素逻辑由 artop_test 的 sendCanvas 用例覆盖。
  sentText, sentBin = {}, {}
  conn:sendBinary({ type = "upload", id = 1, name = "a.png", width = 3, height = 4 }, "0123456789ab")
  local up = json.decode(sentText[1])
  ok(up.type == "upload" and up.binary == true and up.name == "a.png", "上传头帧形状对：" .. tostring(up.type))
  ok(sentBin[1] == "0123456789ab", "上传负载对")
end

print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error("ws_test failed: " .. fail) end
