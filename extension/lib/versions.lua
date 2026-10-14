-- lib/versions.lua -- 快照 / 回滚 / 临时版本管理
--
-- 两层：
--   1. 内存快照：所有 cel 的原始像素字节 + 位置 + 调色板。回滚时用
--      cel.image = Image(...) 写回（已实测可撤销），瞬间完成、不用读盘。
--   2. 磁盘副本：同时 sprite:saveCopyAs() 存一份 .aseprite 到用户配置目录，
--      用于跨会话留存，以及图层结构变化后的完整还原（走 app.open）。
--
-- 每个 sprite 独立一条版本栈，最多保留 MAX_VERSIONS 条。

local versions = {}

local MAX_VERSIONS = 20
local MAX_MEMORY_BYTES = 64 * 1024 * 1024

local stacks = {}   -- [spriteId] = { entries = {...}, seq = n }

local function stackFor(sprite, create)
  local id = sprite.id
  local st = stacks[id]
  if not st and create then
    st = { entries = {}, seq = 0 }
    stacks[id] = st
  end
  return st
end

local function versionsDir()
  local dir = app.fs.joinPath(app.fs.userConfigPath, "ai-pixel-copilot")
  dir = app.fs.joinPath(dir, "versions")
  if not app.fs.isDirectory(dir) then
    app.fs.makeAllDirectories(dir)
  end
  return dir
end

local function spriteTitle(sprite)
  local fn = sprite.filename
  local title = (fn and fn ~= "") and app.fs.fileTitle(fn) or "untitled"
  return (title:gsub("[^%w_%-%.]", "_"))
end

local function findCel(sprite, layerName, frameNumber)
  for i = 1, #sprite.layers do
    local layer = sprite.layers[i]
    if layer.name == layerName then
      return layer:cel(frameNumber)
    end
  end
  return nil
end

-- 抓取当前 sprite 的完整状态
local function capture(sprite)
  local cels, totalBytes = {}, 0
  for i = 1, #sprite.cels do
    local cel = sprite.cels[i]
    local img = cel.image
    if img then
      local bytes = img.bytes
      totalBytes = totalBytes + #bytes
      cels[#cels + 1] = {
        layer = cel.layer.name,
        frame = cel.frameNumber,
        x = cel.position.x,
        y = cel.position.y,
        w = img.width,
        h = img.height,
        colorMode = img.colorMode,
        bytes = bytes,
      }
    end
  end

  local palette = {}
  local pal = sprite.palettes[1]
  for i = 0, #pal - 1 do
    local c = pal:getColor(i)
    palette[#palette + 1] = { c.red, c.green, c.blue, c.alpha }
  end

  return cels, palette, totalBytes
end

local function prune(st)
  while #st.entries > MAX_VERSIONS do
    local old = table.remove(st.entries, 1)
    if old.file and app.fs.isFile(old.file) then
      os.remove(old.file)
    end
  end
end

-- 记一条快照，返回元信息（不含像素字节）
function versions.push(label, sprite)
  sprite = sprite or app.activeSprite
  if not sprite then error("no document is open") end

  local st = stackFor(sprite, true)
  st.seq = st.seq + 1

  local cels, palette, totalBytes = capture(sprite)
  local memory = totalBytes <= MAX_MEMORY_BYTES

  local meta = {
    id = st.seq,
    label = label or ("version " .. st.seq),
    ts = os.time(),
    date = os.date("%Y-%m-%d %H:%M:%S"),
    sprite = spriteTitle(sprite),
    width = sprite.width,
    height = sprite.height,
    cels = #cels,
    bytes = totalBytes,
    memory = memory,
  }

  -- 磁盘副本（失败不致命，只是少了持久化）
  local file = app.fs.joinPath(versionsDir(),
    string.format("%s_v%03d_%s.aseprite", meta.sprite, st.seq, os.date("%Y%m%d_%H%M%S")))
  local ok = false
  pcall(function() ok = sprite:saveCopyAs(file) end)
  meta.file = ok and file or nil

  local entry = {
    meta = meta,
    cels = memory and cels or nil,
    palette = memory and palette or nil,
  }
  st.entries[#st.entries + 1] = entry
  prune(st)

  return meta
end

function versions.list(sprite)
  sprite = sprite or app.activeSprite
  if not sprite then return {} end
  local st = stackFor(sprite, false)
  if not st then return {} end
  local out = {}
  for i, e in ipairs(st.entries) do
    local m = {}
    for k, v in pairs(e.meta) do m[k] = v end
    m.index = i
    m.isLast = (i == #st.entries)
    out[#out + 1] = m
  end
  return out
end

function versions.count(sprite)
  return #versions.list(sprite)
end

function versions.clear(sprite)
  sprite = sprite or app.activeSprite
  if not sprite then return end
  local st = stackFor(sprite, false)
  if not st then return end
  for _, e in ipairs(st.entries) do
    if e.meta.file and app.fs.isFile(e.meta.file) then os.remove(e.meta.file) end
  end
  st.entries = {}
end

-- 回滚到指定版本号（id）。'last' 表示上一个版本。
function versions.rollback(id, sprite)
  sprite = sprite or app.activeSprite
  if not sprite then error("no document is open") end
  local st = stackFor(sprite, false)
  if not st or #st.entries == 0 then error("no snapshots yet") end

  local target
  if id == nil or id == "last" then
    target = st.entries[#st.entries]
  else
    for _, e in ipairs(st.entries) do
      if e.meta.id == tonumber(id) then target = e break end
    end
  end
  if not target then error("version not found: " .. tostring(id)) end

  local meta = target.meta
  if not target.cels then
    error("version " .. meta.id .. " only exists as an on-disk copy (too large for memory); open it manually: " .. tostring(meta.file))
  end

  local matched, missing = 0, {}
  app.transaction("AI: rollback to " .. meta.label, function()
    for _, c in ipairs(target.cels) do
      local cel = findCel(sprite, c.layer, c.frame)
      if cel then
        local img = Image(c.w, c.h, c.colorMode)
        img.bytes = c.bytes
        cel.image = img
        cel.position = Point(c.x, c.y)
        matched = matched + 1
      else
        missing[#missing + 1] = c.layer .. "#" .. c.frame
      end
    end
    local pal = sprite.palettes[1]
    for i = 1, #target.palette do
      if i - 1 < #pal then
        local c = target.palette[i]
        pal:setColor(i - 1, Color(c[1], c[2], c[3], c[4]))
      end
    end
  end)

  return {
    id = meta.id,
    label = meta.label,
    date = meta.date,
    matched = matched,
    total = #target.cels,
    missing = missing,
    file = meta.file,
  }
end

return versions
