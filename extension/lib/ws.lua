-- lib/ws.lua -- WebSocket 客户端封装
--
-- Aseprite 的 Lua 只有 WebSocket，没有 HTTP 客户端（ENABLE_WEBSOCKET=ON）。
-- 回调签名是三个位置参数： onreceive(msgType, data, error)
-- （见 Aseprite 源码 src/app/script/websocket_class.cpp 的 lua_pcall(L, 3, 0, 0)）
--
-- 协议：控制消息走 JSON 文本帧；像素数据走二进制帧，并在其前发一个
-- JSON 头帧声明尺寸，接收端按顺序配对。
--
-- 重要：WebSocket 对象必须被长期持有，否则被 GC 回收时 __gc 会关掉连接。
-- 本模块把它存在模块级 upvalue + 全局引用里。

local ws = {}

local Conn = {}
Conn.__index = Conn

-- Aseprite 的 json.decode 返回的是 JsonObj userdata，不是 Lua table
-- （src/app/script/json_class.cpp 的 Json_decode 用 push_obj 推 json11::Json）。
-- 它支持 obj.key / obj[i] / #obj，但这一版里数组的 ipairs/pairs 迭代器有 bug
-- （JsonObj_ipairs_next 返回 0 而不是 2，循环会立刻结束），所以数组必须用
-- #obj + obj[i] 逐项取。这里统一转成普通 table，后面所有代码就都能照常写。
local function fromJson(v)
  if type(v) ~= "userdata" then return v end

  local okLen, n = pcall(function() return #v end)
  if okLen and type(n) == "number" and n > 0 and v[1] ~= nil then
    local out = {}
    for i = 1, n do out[i] = fromJson(v[i]) end
    return out
  end

  local out = {}
  for k, val in pairs(v) do out[k] = fromJson(val) end
  return out
end

ws.fromJson = fromJson

-- handlers = {
--   onOpen   = function() end,
--   onText   = function(table) end,
--   onBinary = function(headerTable, data) end,   -- header 为上一个 JSON 头帧
--   onClose  = function() end,
--   onError  = function(text) end,
-- }
function ws.connect(url, handlers)
  local self = setmetatable({
    url = url,
    handlers = handlers or {},
    state = "connecting",
    pendingBinaryHeader = nil,
  }, Conn)

  local ok, err = pcall(function()
    self.socket = WebSocket{
      url = url,
      deflate = false,
      minreconnectwait = 1,
      maxreconnectwait = 5,
      onreceive = function(msgType, data, errText)
        self:_receive(msgType, data, errText)
      end,
    }
    self.socket:connect()
  end)
  if not ok then
    self.state = "error"
    if self.handlers.onError then self.handlers.onError(tostring(err)) end
  end

  -- 防 GC
  ws._keepAlive = ws._keepAlive or {}
  ws._keepAlive[#ws._keepAlive + 1] = self
  return self
end

function Conn:_receive(msgType, data, errText)
  local T = WebSocketMessageType
  if msgType == T.OPEN then
    self.state = "open"
    if self.handlers.onOpen then self.handlers.onOpen() end
  elseif msgType == T.TEXT then
    local ok, decoded = pcall(json.decode, data)
    if not ok then
      if self.handlers.onError then
        self.handlers.onError("json.decode failed: " .. tostring(decoded))
      end
      return
    end
    local msg = fromJson(decoded)
    if type(msg) ~= "table" then
      if self.handlers.onError then
        self.handlers.onError("text frame did not decode to an object: " .. tostring(data):sub(1, 200))
      end
      return
    end
    if msg.type == "binary_header" then
      self.pendingBinaryHeader = msg
    elseif self.handlers.onText then
      self.handlers.onText(msg)
    end
  elseif msgType == T.BINARY then
    local header = self.pendingBinaryHeader
    self.pendingBinaryHeader = nil
    if self.handlers.onBinary then
      self.handlers.onBinary(header or {}, data)
    end
  elseif msgType == T.CLOSE then
    self.state = "closed"
    if self.handlers.onClose then self.handlers.onClose() end
  elseif msgType == T.ERROR then
    self.state = "error"
    if self.handlers.onError then self.handlers.onError(tostring(errText)) end
  end
end

function Conn:isOpen()
  return self.state == "open"
end

function Conn:send(tbl)
  if not self.socket then return false end
  local ok, err = pcall(function()
    self.socket:sendText(json.encode(tbl))
  end)
  if not ok then
    if self.handlers.onError then self.handlers.onError(tostring(err)) end
    return false
  end
  return true
end

-- 先发 JSON 头帧，再发二进制负载
function Conn:sendBinary(header, data)
  if not self.socket then return false end
  header.type = "binary_header"
  local ok, err = pcall(function()
    self.socket:sendText(json.encode(header))
    self.socket:sendBinary(data)
  end)
  if not ok then
    if self.handlers.onError then self.handlers.onError(tostring(err)) end
    return false
  end
  return true
end

function Conn:close()
  if self.socket then
    pcall(function() self.socket:close() end)
    self.socket = nil
  end
  self.state = "closed"
end

return ws
