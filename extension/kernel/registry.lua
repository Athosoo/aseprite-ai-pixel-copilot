-- kernel/registry.lua -- 能力注册表（§3.2）
-- 五种 kind 的规格形状是冻结的：这里只做校验，不认识的东西一律拒绝，
-- 免得 packs 里写错的声明悄悄混进 UI。
local Registry = {}
Registry.__index = Registry

local KINDS = {
  view    = { key = "id",   required = { "id", "title", "mount" } },
  command = { key = "id",   required = { "id", "title", "run" } },
  op      = { key = "name", required = { "name", "run" } },
  action  = { key = "id",   required = { "id", "run" } },
  tool    = { key = "name", required = { "name", "description", "inputSchema", "run" } },
}
local KIND_ORDER = { "action", "command", "op", "tool", "view" }
local DEFAULT_ORDER = 100

local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

function Registry.new(opts)
  opts = opts or {}
  local data = {}
  for k in pairs(KINDS) do data[k] = {} end
  return setmetatable({
    data = data,
    rev = 0,
    bus = opts.bus,
  }, Registry)
end

function Registry:kinds()
  -- 固定返回五种，顺序稳定：UI 的缓存 key 不能因为"当前有没有 op"而抖
  local out = {}
  for i = 1, #KIND_ORDER do out[i] = KIND_ORDER[i] end
  return out
end

function Registry:define(kind, spec)
  local def = KINDS[kind]
  if not def then return false, "unknown kind " .. tostring(kind) end
  if type(spec) ~= "table" then return false, kind .. ": spec must be a table" end

  local id = spec[def.key]
  if type(id) ~= "string" or id == "" then
    return false, string.format("%s: %s must be a non-empty string", kind, def.key)
  end

  local missing = {}
  for _, field in ipairs(def.required) do
    local v = spec[field]
    local wantFn = (field == "run" or field == "mount" or field == "refresh" or field == "unmount")
    if v == nil then
      missing[#missing + 1] = field
    elseif wantFn and type(v) ~= "function" then
      return false, string.format("%s %q: %s must be a function", kind, id, field)
    elseif field == "inputSchema" and type(v) ~= "table" then
      return false, string.format("%s %q: inputSchema must be a table", kind, id)
    elseif not wantFn and field == "title" and type(v) ~= "string" then
      return false, string.format("%s %q: title must be a string", kind, id)
    end
  end
  if #missing > 0 then
    return false, string.format("%s %q: missing field(s) %s", kind, id, table.concat(missing, ", "))
  end

  local order = spec.order
  if order == nil then order = DEFAULT_ORDER end
  if type(order) ~= "number" then
    return false, string.format("%s %q: order must be a number", kind, id)
  end

  local bucket = self.data[kind]
  if not bucket[id] then self.rev = self.rev + 1 end  -- 纯覆盖不算结构变更
  bucket[id] = spec
  self.rev = self.rev + 1

  if self.bus then
    pcall(function() self.bus:emit("registry.changed", { kind = kind, id = id }) end)
  end
  return true
end

function Registry:get(kind, id)
  local bucket = self.data[kind]
  if not bucket then return nil end
  return bucket[id]
end

function Registry:list(kind)
  local bucket = self.data[kind]
  if not bucket then return {} end
  local key = KINDS[kind].key
  local out = {}
  for _, spec in pairs(bucket) do out[#out + 1] = spec end
  -- 顺序归一：先按 order，再按 id —— 热重载后列表不能跳来跳去
  table.sort(out, function(a, b)
    local oa = a.order or DEFAULT_ORDER
    local ob = b.order or DEFAULT_ORDER
    if oa ~= ob then return oa < ob end
    return tostring(a[key]) < tostring(b[key])
  end)
  return out
end

function Registry:remove(kind, id)
  local bucket = self.data[kind]
  if not bucket or not bucket[id] then return false end
  bucket[id] = nil
  self.rev = self.rev + 1
  if self.bus then
    pcall(function() self.bus:emit("registry.changed", { kind = kind, id = id }) end)
  end
  return true
end

function Registry:fingerprint()
  local parts = {}
  for _, kind in ipairs(self:kinds()) do
    local bucket = self.data[kind] or {}
    local key = KINDS[kind].key
    local ids = {}
    for id in pairs(bucket) do ids[#ids + 1] = id end
    table.sort(ids)
    local row = {}
    for i = 1, #ids do
      local spec = bucket[ids[i]]
      row[i] = string.format("%s@%d", tostring(ids[i]), spec.order or DEFAULT_ORDER)
    end
    parts[#parts + 1] = kind .. "=" .. table.concat(row, ",")
  end
  local canonical = table.concat(parts, ";")
  return hash(canonical) .. "-" .. tostring(self.rev)
end

return Registry
