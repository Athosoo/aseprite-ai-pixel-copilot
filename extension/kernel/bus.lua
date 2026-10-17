-- kernel/bus.lua -- 事件总线（§3.1）
-- emit 同步派发。任何一个 handler 抛错都不能影响其它 handler，也不能冒泡到 UI：
-- 所以逐个 pcall，错误写进 journal（账本）。
local Bus = {}
Bus.__index = Bus

local nextId = 0

function Bus.new(opts)
  opts = opts or {}
  return setmetatable({
    handlers = {},   -- [name] = { [id] = fn }
    order = {},      -- [name] = { id, ... } 保持注册顺序
    queue = {},      -- ws 回调推入的事件，由 GUI 定时器 drain
    journal = opts.journal or function() end,
    errors = 0,
  }, Bus)
end

function Bus:on(name, fn)
  if type(name) ~= "string" then return nil, "bus:on: name must be a string" end
  if type(fn) ~= "function" then return nil, "bus:on: handler must be a function" end
  nextId = nextId + 1
  local id = nextId
  if not self.handlers[name] then
    self.handlers[name] = {}
    self.order[name] = {}
  end
  self.handlers[name][id] = fn
  local list = self.order[name]
  list[#list + 1] = id
  return id
end

function Bus:off(id)
  if id == nil then return false end
  for name, bucket in pairs(self.handlers) do
    if bucket[id] then
      bucket[id] = nil
      local list = self.order[name]
      for i = #list, 1, -1 do
        if list[i] == id then table.remove(list, i) end
      end
      return true
    end
  end
  return false
end

function Bus:count(name)
  local list = self.order[name]
  return list and #list or 0
end

function Bus:emit(name, payload)
  local list = self.order[name]
  if not list then return 0 end
  local bucket = self.handlers[name]
  -- 先拷贝 id 列表：handler 里 on/off 不得打断本次派发
  local ids = {}
  for i = 1, #list do ids[i] = list[i] end
  local delivered = 0
  for i = 1, #ids do
    local fn = bucket[ids[i]]
    if fn then
      local ok, err = pcall(fn, payload)
      delivered = delivered + 1
      if not ok then
        self.errors = self.errors + 1
        pcall(self.journal, { event = "bus.error", name = name, err = tostring(err) })
      end
    end
  end
  return delivered
end

-- 只入队不派发。ws 回调在 Aseprite 的事件循环里跑，直接改 UI 状态会踩重入，
-- 所以先攒起来，等 GUI 定时器调 drain() 再统一派发。
function Bus:push(name, payload)
  self.queue[#self.queue + 1] = { name = name, payload = payload }
  return #self.queue
end

function Bus:drain()
  local handled = 0
  local rounds = 0
  while #self.queue > 0 do
    rounds = rounds + 1
    if rounds > 64 then
      -- handler 里再 push 造成自激：记一笔然后丢弃，绝不在这里挂死 UI
      self.errors = self.errors + 1
      pcall(self.journal, { event = "bus.error", name = "drain", err = "queue kept refilling; dropped " .. #self.queue })
      self.queue = {}
      break
    end
    local batch = self.queue
    self.queue = {}
    for i = 1, #batch do
      self:emit(batch[i].name, batch[i].payload)
      handled = handled + 1
    end
  end
  return handled
end

return Bus
