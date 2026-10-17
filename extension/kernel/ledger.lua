-- kernel/ledger.lua -- 能力账本 + JSONL journal（§3.6）
-- 账本自己不许写死路径：journal 目录、时钟、文件系统全部可注入，
-- 否则它只能在真人点开 Aseprite 之后才测得了。
local Ledger = {}
Ledger.__index = Ledger

local DEFAULT_MAX_LINES = 2000
local KEEP_BACKUPS = 3
local API_VERSION = 1
-- 闭集：声明 io 才能读写工作区，os 只给"读时钟"那半边（见 dsl.lua）
local PERMISSION_SET = { io = true, os = true }

local function join(fs, a, b)
  if fs and fs.joinPath then
    local ok, p = pcall(fs.joinPath, a, b)
    if ok and type(p) == "string" then return p end
  end
  return tostring(a) .. "/" .. tostring(b)
end

-- json.decode 返回 JsonObj userdata（数组的 ipairs/pairs 有 bug），统一转普通 table
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

local function defaultJournalDir(fs)
  if fs and fs.userConfigPath then
    return join(fs, join(fs, fs.userConfigPath, "ai-pixel-copilot"), "journal")
  end
  local appdata = os and os.getenv and os.getenv("APPDATA")
  if appdata and appdata ~= "" then return appdata .. "/Aseprite/ai-pixel-copilot/journal" end
  return "ai-pixel-copilot-journal"
end

function Ledger.new(dirOrOpts)
  local o = {}
  if type(dirOrOpts) == "string" then
    o.dir = dirOrOpts
  elseif type(dirOrOpts) == "table" then
    o = dirOrOpts
  end

  local fs = o.fs or (_G.app and _G.app.fs) or nil
  local self = setmetatable({
    fs = fs,
    clock = o.clock or function() return os.time() end,
    maxLines = tonumber(o.maxLines) or DEFAULT_MAX_LINES,
    -- packs 目录顺序即加载顺序：builtin 先、user 后，同 id 后者覆盖前者
    packsDirs = o.packsDirs or {},
    encode = o.encode or (_G.json and _G.json.encode) or nil,
    decode = o.decode or (_G.json and _G.json.decode) or nil,
    listDir = o.listDir,
    isDir = o.isDir,
    isFile = o.isFile,
    rename = o.rename or (os and os.rename) or nil,
    remove = o.remove or (os and os.remove) or nil,
    -- 只发事件、不认识 agent：谁需要「包没了→撤算子」由入口订阅去接
    bus = o.bus or nil,
    events = {},
    healthMap = {},
    lines = nil,
    writeFails = 0,
  }, Ledger)

  self.dir = o.dir or defaultJournalDir(fs)
  self.file = join(fs, self.dir, "journal.jsonl")
  self.stateFile = join(fs, self.dir, "state.json")
  return self
end

function Ledger:_ensureDir(dir)
  if self.fs and self.fs.isDirectory then
    local ok, exists = pcall(function() return self.fs.isDirectory(dir) end)
    if ok and exists then return true end
    local ok2 = pcall(function() self.fs.makeAllDirectories(dir) end)
    return ok2
  end
  return false
end

function Ledger:_decode(text)
  if type(self.decode) ~= "function" then return nil, "no json decoder available" end
  local ok, obj = pcall(self.decode, text)
  if not ok then return nil, tostring(obj) end
  return fromJson(obj)
end

function Ledger:_encode(rec)
  if type(self.encode) == "function" then
    local ok, s = pcall(self.encode, rec)
    if ok and type(s) == "string" then return s end
  end
  -- json 不可用时退回 key=value 单行：仍是一行一条，journal 不会因此断掉
  local parts = {}
  for k, v in pairs(rec) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  return table.concat(parts, " ")
end

function Ledger:_countFileLines()
  local f = io.open(self.file, "rb")
  if not f then return 0 end
  local n = 0
  for _ in f:lines() do n = n + 1 end
  f:close()
  return n
end

function Ledger:_writeAll(records)
  local tmp = self.file .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  for i = 1, #records do
    local ok, line = pcall(self._encode, self, records[i])
    if ok then f:write(line, "\n") end
  end
  f:close()
  if self.rename then
    pcall(self.rename, self.file, self.file .. ".old")
    pcall(self.remove, self.file .. ".old")
    local ok = pcall(self.rename, tmp, self.file)
    if ok then return true end
  end
  -- 没有 rename 就直接覆盖写（测试环境与退路都走这里）
  local out = io.open(self.file, "wb")
  if not out then return false end
  local src = io.open(tmp, "rb")
  if src then out:write(src:read("*a")); src:close() end
  out:close()
  pcall(function() if self.remove then self.remove(tmp) end end)
  return true
end

function Ledger:_append(line)
  if self.lines == nil then self.lines = self:_countFileLines() end
  if self.lines >= self.maxLines then
    -- 环形上限：超出就按内存里保留的最后 maxLines 条重写。
    -- 最后一条就是马上要 append 的这条，别再写第二遍。
    local keep = {}
    for i = 1, #self.events - 1 do keep[i] = self.events[i] end
    self:_writeAll(keep)
    self.lines = #keep
  end
  self:_ensureDir(self.dir)
  local f = io.open(self.file, "ab")
  if not f then
    self.writeFails = self.writeFails + 1
    return false
  end
  f:write(line, "\n")
  f:close()
  self.lines = self.lines + 1
  return true
end

function Ledger:journal(event)
  local rec = { ts = self.clock() }
  if type(event) == "table" then
    for k, v in pairs(event) do rec[k] = v end
  elseif event ~= nil then
    rec.event = tostring(event)
  end

  local ring = self.events
  ring[#ring + 1] = rec
  while #ring > self.maxLines do table.remove(ring, 1) end

  local ok, line = pcall(self._encode, self, rec)
  if not ok then
    self.writeFails = self.writeFails + 1
    return false
  end
  return self:_append(line)
end

function Ledger:tail(n)
  n = tonumber(n) or 20
  local out, total = {}, #self.events
  for i = math.max(1, total - n + 1), total do out[#out + 1] = self.events[i] end
  return out
end

function Ledger:_listDir(dir)
  if self.listDir then return self.listDir(dir) end
  if self.fs and self.fs.listFiles then
    local ok, names = pcall(self.fs.listFiles, dir)
    if ok and type(names) == "table" then return names end
  end
  return {}
end

function Ledger:_dirOk(path)
  if self.isDir then return self.isDir(path) end
  if self.fs and self.fs.isDirectory then
    local ok, v = pcall(function() return self.fs.isDirectory(path) end)
    return ok and v or false
  end
  return false
end

function Ledger:_fileOk(path)
  if self.isFile then return self.isFile(path) end
  if self.fs and self.fs.isFile then
    local ok, v = pcall(function() return self.fs.isFile(path) end)
    return ok and v or false
  end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

function Ledger:_readText(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function Ledger:_parseManifest(dir)
  local path = join(self.fs, dir, "manifest.json")
  local text = self:_readText(path)
  if not text then return nil, "missing manifest.json" end
  local m, derr = self:_decode(text)
  if type(m) ~= "table" then return nil, "manifest.json is not valid JSON: " .. tostring(derr) end

  if type(m.id) ~= "string" or m.id == "" then return nil, "manifest.id is required" end
  if m.api == nil then
    return nil, string.format("manifest.api is required (kernel api is %d)", API_VERSION)
  end
  if tonumber(m.api) ~= API_VERSION then
    return nil, string.format("unsupported api %s (kernel api is %d)", tostring(m.api), API_VERSION)
  end

  local perms = {}
  if m.permissions ~= nil then
    for i = 1, #m.permissions do
      local p = tostring(m.permissions[i])
      if not PERMISSION_SET[p] then
        return nil, string.format("permission %q is not in the closed set {io, os}", p)
      end
      perms[#perms + 1] = p
    end
  end

  if not self:_fileOk(join(self.fs, dir, "main.lua")) then
    return nil, "missing main.lua (every pack must expose return function(ctx) end)"
  end

  local function arr(v)
    local out = {}
    if type(v) == "table" then
      for i = 1, #v do out[#out + 1] = v[i] end
    end
    return out
  end

  return {
    id = m.id,
    name = tostring(m.name or m.id),
    version = tostring(m.version or "0.0.0"),
    api = tonumber(m.api),
    permissions = perms,
    requires = arr(m.requires),
    views = arr(m.views),
    commands = arr(m.commands),
    ops = arr(m.ops),
    dir = dir,
    hasTests = self:_fileOk(join(self.fs, dir, "tests.lua")),
    hasBridgeTools = self:_fileOk(join(self.fs, join(self.fs, dir, "bridge"), "tools.mjs")),
  }
end

-- 发现 packs/*/manifest.json。返回 packs（按目录顺序，同 id 后者覆盖前者）与错误清单；
-- 坏包只进 errors，不许拖累别的包。
function Ledger:scan(dirs)
  dirs = dirs or self.packsDirs
  local packs, errors, index = {}, {}, {}

  for _, root in ipairs(dirs) do
    if self:_dirOk(root) then
      local names = self:_listDir(root)
      table.sort(names)
      for _, nm in ipairs(names) do
        local name = tostring(nm)
        local dir = join(self.fs, root, name)
        -- 备份目录（<id>.bak-N）不是能力包：把它当包会让 scan 的结果回到旧版本
        if self:_dirOk(dir) and name:find("%.bak%-%d+$") == nil then
          local pack, err = self:_parseManifest(dir)
          if pack then
            if index[pack.id] then
              packs[index[pack.id]] = pack
            else
              packs[#packs + 1] = pack
              index[pack.id] = #packs
            end
          else
            errors[#errors + 1] = { id = name, dir = dir, err = tostring(err) }
          end
        end
      end
    end
  end

  for _, e in ipairs(errors) do
    self:journal({ event = "pack.scan_error", id = e.id, dir = e.dir, err = e.err })
  end
  return packs, errors
end

-- ---- 安装 / 启停 / 回滚 -------------------------------------------------

function Ledger:_removeTree(path)
  if self:_dirOk(path) then
    local names = self:_listDir(path)
    for _, nm in ipairs(names) do
      self:_removeTree(join(self.fs, path, tostring(nm)))
    end
  end
  if self.remove then pcall(self.remove, path) end
  return true
end

function Ledger:_copyTree(src, dst)
  self:_ensureDir(dst)
  local names = self:_listDir(src)
  for _, nm in ipairs(names) do
    local name = tostring(nm)
    local from = join(self.fs, src, name)
    local to = join(self.fs, dst, name)
    if self:_dirOk(from) then
      local ok, err = self:_copyTree(from, to)
      if not ok then return false, err end
    else
      local f = io.open(from, "rb")
      if not f then return false, "cannot read " .. from end
      local data = f:read("*a")
      f:close()
      local out = io.open(to, "wb")
      if not out then return false, "cannot write " .. to end
      out:write(data or "")
      out:close()
    end
  end
  return true
end

function Ledger:_bumpBackups(root, id)
  -- 保留最近 KEEP_BACKUPS 个版本：.bak-1 最新，更老的往后挪，超出的删掉
  local dest = join(self.fs, root, id)
  local function bak(n) return join(self.fs, root, id .. ".bak-" .. n) end

  if not self.rename then
    -- 没有 rename：退化成"复制一份当备份"，不删旧版本（宁多勿丢）
    if self:_dirOk(dest) then self:_copyTree(dest, bak(1)) end
    return true
  end

  if self:_dirOk(bak(KEEP_BACKUPS)) then self:_removeTree(bak(KEEP_BACKUPS)) end
  for n = KEEP_BACKUPS - 1, 1, -1 do
    if self:_dirOk(bak(n)) then pcall(self.rename, bak(n), bak(n + 1)) end
  end
  if self:_dirOk(dest) then pcall(self.rename, dest, bak(1)) end
  return true
end

function Ledger:install(srcDir)
  if type(srcDir) ~= "string" or srcDir == "" then return false, "install: srcDir is required" end
  if not self:_dirOk(srcDir) then return false, "install: " .. srcDir .. " is not a directory" end
  local pack, err = self:_parseManifest(srcDir)
  if not pack then return false, "install refused: " .. tostring(err) end
  if #self.packsDirs == 0 then return false, "install: no packs directory configured" end

  local root = self.packsDirs[#self.packsDirs]
  local dest = join(self.fs, root, pack.id)
  self:_bumpBackups(root, pack.id)
  local ok, cerr = self:_copyTree(srcDir, dest)
  if not ok then
    self:journal({ event = "pack.install_failed", id = pack.id, err = tostring(cerr) })
    return false, tostring(cerr)
  end
  self:journal({ event = "pack.install", id = pack.id, version = pack.version, dir = dest })
  return true, pack.id
end

function Ledger:_readState()
  local text = self:_readText(self.stateFile)
  if not text then return { disabled = {} } end
  local st, _ = self:_decode(text)
  if type(st) ~= "table" then return { disabled = {} } end
  st.disabled = st.disabled or {}
  return st
end

function Ledger:_writeState(st)
  self:_ensureDir(self.dir)
  local f = io.open(self.stateFile, "wb")
  if not f then return false end
  local ok, line = pcall(self._encode, self, st)
  if not ok then f:close(); return false end
  f:write(line)
  f:close()
  return true
end

function Ledger:isEnabled(id)
  local st = self:_readState()
  return not st.disabled[id]
end

-- 发事件是"通知"，不是"保证"：订阅方（main.lua → agent）出错不该把 enable/disable 带崩
function Ledger:_emit(name, id)
  if not self.bus then return false end
  local ok = pcall(function() self.bus:emit(name, { id = id }) end)
  return ok
end

function Ledger:enable(id)
  if type(id) ~= "string" or id == "" then return false, "enable: id is required" end
  local st = self:_readState()
  if not st.disabled[id] then return true end
  st.disabled[id] = nil
  self:_writeState(st)
  self:journal({ event = "pack.enable", id = id })
  return true
end

function Ledger:disable(id)
  if type(id) ~= "string" or id == "" then return false, "disable: id is required" end
  local st = self:_readState()
  st.disabled[id] = true
  self:_writeState(st)
  self:journal({ event = "pack.disable", id = id })
  -- 不发出这个事件，registry 里就会留 ghost 算子：模型看得见、一点就 unknown op
  self:_emit("pack.disabled", id)
  return true
end

function Ledger:rollback(id)
  if type(id) ~= "string" or id == "" then return false, "rollback: id is required" end
  if #self.packsDirs == 0 then return false, "rollback: no packs directory configured" end
  local root = self.packsDirs[#self.packsDirs]
  local dest = join(self.fs, root, id)
  local bak = dest .. ".bak-1"
  if not self:_dirOk(bak) then return false, "rollback: no backup for " .. id end

  if self:_dirOk(dest) then self:_removeTree(dest) end
  if self.rename then
    local ok, err = pcall(self.rename, bak, dest)
    if not ok then return false, tostring(err) end
  else
    if self:_dirOk(dest) then return false, "rollback: cannot replace " .. dest .. " without rename support" end
    local ok, cerr = self:_copyTree(bak, dest)
    if not ok then return false, tostring(cerr) end
  end
  self:journal({ event = "pack.rollback", id = id })
  self:_emit("pack.rolledback", id)
  return true
end

-- ---- 健康度 -------------------------------------------------------------

function Ledger:recordCall(id, ms, err)
  if type(id) ~= "string" then return nil end
  local h = self.healthMap[id]
  if not h then
    h = { calls = 0, fails = 0, lastErr = nil, msAvg = 0 }
    self.healthMap[id] = h
  end
  h.calls = h.calls + 1
  local sample = tonumber(ms) or 0
  -- 指数平滑：账本不该为了算均值把每次调用的耗时都存下来
  h.msAvg = h.msAvg + (sample - h.msAvg) / math.min(h.calls, 100)
  if err ~= nil then
    h.fails = h.fails + 1
    h.lastErr = tostring(err)
    self:journal({ event = "pack.call_failed", id = id, err = tostring(err) })
  end
  return h
end

function Ledger:health()
  return self.healthMap
end

function Ledger:markError(id, err)
  return self:recordCall(id, 0, err)
end

return Ledger
