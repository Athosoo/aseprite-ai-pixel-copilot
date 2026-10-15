-- lib/artlib.lua -- 作画：字符网格落像素 / 新建文档 / 建图层
--
-- 设计要点（为了省 token，也为了让模型少犯错）：
--   模型【不输出像素坐标数组】——那会爆 token 且极易写错。
--   它输出的是【字符网格】：每个字符 = 1 个像素，配一张 字符->颜色 的调色板。
--
--     palette = { ["."] = "", ["X"] = "#2E86DE", ["o"] = "#7EE2A8" }
--     rows    = { "..XX..", ".XooX.", "XooooX" }
--
--   16x16 的画大约 100 token，同样的内容用坐标数组要几千。
--   而且字符网格是"所见即所得"的，模型不容易把行宽写歪。
--
-- 分工：ops.lua 改已有像素，sizelib.lua 改文档尺寸，这里负责"从无到有画出来"。

local util = require("lib.util")

local artlib = {}

-- 单个字符 -> Color（或 nil 表示透明）
local function makeColorLookup(palette)
  local map = {}
  for ch, hex in pairs(palette or {}) do
    local k = tostring(ch)
    if k == "" or k == " " or k == "." then
      map[k] = nil            -- 透明
    else
      local r, g, b, a = util.hexToRgb(hex)
      if not r then
        error(string.format("palette entry %q has a bad colour: %s (expected #RRGGBB)", k, tostring(hex)))
      end
      map[k] = Color(r, g, b, a or 255)
    end
  end
  return map
end

-- 把字符网格画到目标 image 上。(x,y) 是网格左上角在画布里的位置。
-- 返回：画了多少像素、用了多少种颜色、以及网格尺寸。
function artlib.stampGrid(img, rows, palette, x, y)
  if type(rows) ~= "table" or #rows == 0 then
    error("rows is empty: pass an array of strings, one per pixel row")
  end

  local lookup = makeColorLookup(palette)
  local w = #rows[1]
  for i, line in ipairs(rows) do
    if #line ~= w then
      error(string.format(
        "row %d has %d characters but row 1 has %d -- every row must be the same width",
        i, #line, w))
    end
  end

  x = math.floor(tonumber(x) or 0)
  y = math.floor(tonumber(y) or 0)

  local painted, skipped = 0, 0
  local used = {}
  for ry, line in ipairs(rows) do
    for rx = 1, w do
      local ch = line:sub(rx, rx)
      local col = lookup[ch]
      if col then
        local px, py = x + rx - 1, y + ry - 1
        if px >= 0 and py >= 0 and px < img.width and py < img.height then
          img:drawPixel(px, py, col)
          painted = painted + 1
          used[tostring(col)] = true
        else
          skipped = skipped + 1     -- 出界：不报错，但要告诉模型，免得它以为画全了
        end
      end
    end
  end

  return {
    painted = painted,
    skippedOutOfBounds = skipped,
    width = w,
    height = #rows,
    distinctColors = (function()
      local n = 0
      for _ in pairs(used) do n = n + 1 end
      return n
    end)(),
  }
end

-- 找图层；没有就建一个（模型不该被迫先建层，多一步多一次出错机会）。
function artlib.ensureLayer(spr, name)
  name = (name and tostring(name)) or ""
  if name == "" then return app.activeLayer end
  for _, layer in ipairs(spr.layers) do
    if layer.name == name then return layer end
  end
  local layer = spr:newLayer()
  layer.name = name
  return layer
end

-- 新建文档。colorMode: "rgb"（默认）/ "indexed" / "grayscale"
function artlib.newSprite(w, h, colorMode)
  w = math.floor(tonumber(w) or 0)
  h = math.floor(tonumber(h) or 0)
  if w < 1 or h < 1 then error("width/height must be at least 1") end
  if w > 4096 or h > 4096 then error("refusing to create larger than 4096x4096") end

  local mode = ColorMode.RGB
  local m = tostring(colorMode or "rgb"):lower()
  if m == "indexed" then mode = ColorMode.INDEXED
  elseif m == "grayscale" or m == "grey" then mode = ColorMode.GRAYSCALE end

  app.command.NewFile{ width = w, height = h, colorMode = mode }
  local spr = app.activeSprite
  if not spr then error("failed to create the document") end
  return spr, { width = spr.width, height = spr.height, colorMode = tostring(spr.colorMode) }
end

-- 在已有文档里加一个图层（放在当前图层之上）。
function artlib.addLayer(spr, name, opts)
  if not spr then error("no document is open") end
  local layer = spr:newLayer()
  if name and tostring(name) ~= "" then
    layer.name = tostring(name)
  end
  opts = opts or {}
  if opts.opacity then
    local o = tonumber(opts.opacity)
    if o then layer.opacity = math.max(0, math.min(255, math.floor(o))) end
  end
  if opts.blendMode then
    local bm = tostring(opts.blendMode):upper()
    local map = {
      NORMAL = BlendMode.NORMAL, MULTIPLY = BlendMode.MULTIPLY, SCREEN = BlendMode.SCREEN,
      OVERLAY = BlendMode.OVERLAY, ADDITION = BlendMode.ADDITION,
    }
    if map[bm] then layer.blendMode = map[bm] end
  end
  return layer, { name = layer.name, opacity = layer.opacity, blendMode = tostring(layer.blendMode) }
end

-- 把字符网格画进某个图层（该层不存在就建）。
-- 整个网格是【一个】撤销步骤。
function artlib.drawArt(spr, spec)
  if not spr then error("no document is open") end
  spec = spec or {}

  local rows = spec.rows
  local palette = spec.palette or {}

  local layerName = spec.layer
  local layer = artlib.ensureLayer(spr, layerName)
  if not layer then error("could not resolve or create the target layer") end

  -- 目标图层可能还没 cel（新建的空层）；在目标位置建一个
  local cel = layer:cel(app.activeFrame or 1)
  if not cel then
    local img = Image(spr.width, spr.height, spr.colorMode)
    cel = spr:newCel(layer, app.activeFrame or 1, img, Point(0, 0))
  end

  local res
  app.transaction("AI: draw " .. (spec.label or "art"), function()
    res = artlib.stampGrid(cel.image, rows, palette, spec.x or 0, spec.y or 0)
  end)

  res.layer = layer.name
  res.canvas = string.format("%dx%d", spr.width, spr.height)
  return res
end

return artlib
