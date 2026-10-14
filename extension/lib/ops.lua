-- lib/ops.lua -- 安全算子（区域级、可撤销）
--
-- 关键实现约束（已实测）：
--   * Image:putPixel / image.bytes= 这类直接写像素【不会】记录撤销信息。
--   * Image:drawImage() / image:clear() 在图像属于某个 cel 时【会】记录撤销信息
--     （见 Aseprite 源码 src/app/script/image_class.cpp:251，走 Tx + cmd::ClearRect）。
--   所以这里一律：在游离的临时 Image 上把结果算完（原始 bytes 写入，快），
--   再用 drawImage(..., BlendMode.SRC) 一次性写回 cel 图像 —— 每个 AI 请求
--   只产生一个可撤销步骤，Ctrl+Z 一步回退。
--
-- 只支持 32 位 RGB/RGBA 图层（每像素 4 字节）。Indexed/Gray 会明确报错。

local util = require("lib.util")

local ops = {}

local MAX_REGION_PIXELS = 262144 -- 512x512，逐像素算子的上限

local function hexHasAlpha(s)
  return type(s) == "string" and #(s:gsub("^#", "")) == 8
end

-- 在 region 内逐像素调用 fn(x, y, r, g, b, a)；返回 nil 表示保留原像素。
-- 返回值写入游离图像后整体写回，保证可撤销。返回改变的像素数。
local function transform(img, region, fn)
  if img.bytesPerPixel ~= 4 then
    error(string.format(
      "only 32-bit RGB/RGBA layers are supported (this one is %d bytes per pixel). " ..
      "Convert with Sprite > Color Mode > RGB first.",
      img.bytesPerPixel))
  end
  local w, h, stride = img.width, img.height, img.rowStride
  region = util.normRegion(region, w, h)
  if region.w <= 0 or region.h <= 0 then return 0 end
  if region.w * region.h > MAX_REGION_PIXELS then
    error(string.format("region too large: %dx%d (limit 512x512). Narrow it down first.", region.w, region.h))
  end

  local src = img.bytes
  local out, n = {}, 0
  local pos = 1
  local changed = 0

  for y = region.y, region.y + region.h - 1 do
    local a = y * stride + region.x * 4 + 1
    local b = a + region.w * 4 - 1
    if a > pos then
      n = n + 1
      out[n] = src:sub(pos, a - 1)
    end
    local row = {}
    for i = 0, region.w - 1 do
      local p = a + i * 4
      local r, g, bl, al = src:byte(p, p + 3)
      local nr, ng, nb, na = fn(region.x + i, y, r, g, bl, al)
      if nr then
        row[#row + 1] = string.char(nr, ng, nb, na)
        if nr ~= r or ng ~= g or nb ~= bl or na ~= al then
          changed = changed + 1
        end
      else
        row[#row + 1] = src:sub(p, p + 3)
      end
    end
    n = n + 1
    out[n] = table.concat(row)
    pos = b + 1
  end
  n = n + 1
  out[n] = src:sub(pos)

  if changed > 0 then
    local scratch = Image(w, h, img.colorMode)
    scratch.bytes = table.concat(out)
    img:drawImage(scratch, Point(0, 0), 255, BlendMode.SRC)
  end
  return changed
end

-- 读原始像素（不修改）
local function pixelAt(img, x, y)
  local stride = img.rowStride
  local p = y * stride + x * 4 + 1
  return img.bytes:byte(p, p + 3)
end

local function alphaAt(src, stride, x, y, w, h)
  if x < 0 or y < 0 or x >= w or y >= h then return 0 end
  return src:byte(y * stride + x * 4 + 4)
end

----------------------------------------------------------------------
-- 算子
----------------------------------------------------------------------

-- 把某个颜色的像素换成另一个颜色。to 为 6 位时保留原 alpha。
local function op_replace_color(img, o)
  local fr, fg, fb = util.hexToRgb(o.from)
  if not fr then error("replace_color: 'from' must look like #RRGGBB") end
  local tr, tg, tb, ta = util.hexToRgb(o.to)
  if not tr then error("replace_color: 'to' must look like #RRGGBB") end
  local keepAlpha = not hexHasAlpha(o.to)
  local tol = tonumber(o.tolerance) or 0
  return transform(img, o.region, function(x, y, r, g, b, a)
    if math.abs(r - fr) <= tol and math.abs(g - fg) <= tol and math.abs(b - fb) <= tol then
      return tr, tg, tb, keepAlpha and a or ta
    end
    return nil
  end)
end

-- 删除某个颜色（变透明）
local function op_erase_color(img, o)
  local fr, fg, fb = util.hexToRgb(o.color)
  if not fr then error("erase_color: 'color' must look like #RRGGBB") end
  local tol = tonumber(o.tolerance) or 0
  return transform(img, o.region, function(x, y, r, g, b, a)
    if a > 0 and math.abs(r - fr) <= tol and math.abs(g - fg) <= tol and math.abs(b - fb) <= tol then
      return 0, 0, 0, 0
    end
    return nil
  end)
end

-- 清空一个矩形区域
local function op_erase_region(img, o)
  return transform(img, o.region, function() return 0, 0, 0, 0 end)
end

-- 用纯色填充一个矩形区域
local function op_fill_region(img, o)
  local r, g, b, a = util.hexToRgb(o.color)
  if not r then error("fill_region: 'color' must look like #RRGGBB") end
  return transform(img, o.region, function() return r, g, b, a end)
end

-- 给不透明像素外描一圈 1px 边（只画在原本透明的位置）
local function op_outline(img, o)
  local r, g, b = util.hexToRgb(o.color)
  if not r then error("outline: 'color' must look like #RRGGBB") end
  local w, h, stride = img.width, img.height, img.rowStride
  local src = img.bytes
  return transform(img, o.region, function(x, y, pr, pg, pb, pa)
    if pa > 0 then return nil end
    if alphaAt(src, stride, x - 1, y, w, h) > 0
      or alphaAt(src, stride, x + 1, y, w, h) > 0
      or alphaAt(src, stride, x, y - 1, w, h) > 0
      or alphaAt(src, stride, x, y + 1, w, h) > 0 then
      return r, g, b, 255
    end
    return nil
  end)
end

-- 清理孤立杂点：删掉不透明连通域大小 <= maxCluster 的簇（4 连通）
local function op_despeckle(img, o)
  local maxCluster = tonumber(o.maxCluster) or 1
  local w, h, stride = img.width, img.height, img.rowStride
  local region = util.normRegion(o.region, w, h)
  if region.w * region.h > MAX_REGION_PIXELS then
    error("despeckle: region too large (limit 512x512)")
  end
  local src = img.bytes
  local visited, remove = {}, {}
  local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

  for y = region.y, region.y + region.h - 1 do
    for x = region.x, region.x + region.w - 1 do
      local k = y * w + x
      if not visited[k] and alphaAt(src, stride, x, y, w, h) > 0 then
        local queue, qi, cluster = { k }, 1, {}
        visited[k] = true
        while qi <= #queue do
          local ck = queue[qi]
          qi = qi + 1
          cluster[#cluster + 1] = ck
          local cx, cy = ck % w, math.floor(ck / w)
          for i = 1, 4 do
            local nx, ny = cx + dirs[i][1], cy + dirs[i][2]
            if nx >= 0 and nx < w and ny >= 0 and ny < h then
              local nk = ny * w + nx
              if not visited[nk] and alphaAt(src, stride, nx, ny, w, h) > 0 then
                visited[nk] = true
                queue[#queue + 1] = nk
              end
            end
          end
        end
        if #cluster <= maxCluster then
          for i = 1, #cluster do remove[cluster[i]] = true end
        end
      end
    end
  end

  if not next(remove) then return 0 end
  return transform(img, region, function(x, y)
    if remove[y * w + x] then return 0, 0, 0, 0 end
    return nil
  end)
end

-- 按映射表批量换色，并同步改调色板
local function op_palette_map(img, o, sprite)
  local map = o.map
  if type(map) ~= "table" or not next(map) then
    error('palette_map: map must look like { "#old": "#new" }')
  end
  local total = 0
  for from, to in pairs(map) do
    total = total + op_replace_color(img, {
      from = from, to = to, region = o.region, tolerance = o.tolerance,
    })
  end
  local palChanged = 0
  if o.updatePalette ~= false and sprite then
    local pal = sprite.palettes[1]
    for i = 0, #pal - 1 do
      local c = pal:getColor(i)
      local hex = util.rgbToHex(c.red, c.green, c.blue)
      local to = map[hex] or map[hex:lower()] or map[hex:upper()]
      if to then
        local r, g, b = util.hexToRgb(to)
        if r then
          pal:setColor(i, Color(r, g, b))
          palChanged = palChanged + 1
        end
      end
    end
  end
  return total, palChanged
end

local OPS = {
  replace_color = { fn = op_replace_color, desc = "replace pixels of one colour with another (tolerance absorbs anti-aliased edges)" },
  erase_color   = { fn = op_erase_color,   desc = "make pixels of one colour transparent" },
  erase_region  = { fn = op_erase_region,  desc = "clear a rectangular region to transparent" },
  fill_region   = { fn = op_fill_region,   desc = "fill a rectangular region with a solid colour" },
  outline       = { fn = op_outline,       desc = "draw a 1px outline around opaque pixels, on previously transparent pixels" },
  despeckle     = { fn = op_despeckle,     desc = "delete isolated blobs up to maxCluster pixels (1 = single stray pixel)" },
  palette_map   = { fn = op_palette_map,   desc = "remap colours by { old: new } and update the palette too" },
}

ops.names = {}
for name in pairs(OPS) do ops.names[#ops.names + 1] = name end
table.sort(ops.names)

function ops.describe()
  local out = {}
  for _, name in ipairs(ops.names) do
    out[#out + 1] = "- " .. name .. "：" .. OPS[name].desc
  end
  return table.concat(out, "\n")
end

-- 在单个事务里执行一串算子。label 会成为撤销步骤的名字。
-- targetCel 可选（默认当前活动 cel），传参是为了让无头测试能指定目标。
function ops.run(list, label, targetCel)
  local cel = targetCel or app.activeCel
  if not cel or not cel.image then error("the current layer has no editable cel; select a layer first") end
  local sprite = cel.sprite or app.activeSprite
  if not sprite then error("no document is open") end
  if type(list) ~= "table" or #list == 0 then error("nothing to execute") end

  local img = cel.image
  local reports = {}

  app.transaction("AI: " .. (label or "编辑"), function()
    for i, op in ipairs(list) do
      local name = op.op or op.type
      local entry = OPS[name]
      if not entry then
        error("unknown op " .. tostring(name) .. "; available ops: " .. table.concat(ops.names, ", "))
      end
      local changed, extra = entry.fn(img, op, sprite)
      reports[#reports + 1] = {
        index = i, op = name, changed = changed or 0, extra = extra,
      }
    end
  end)

  return {
    sprite = (sprite.filename ~= "" and app.fs.fileName(sprite.filename)) or "(未命名)",
    layer = cel.layer.name,
    frame = cel.frameNumber,
    ops = reports,
  }
end

-- 统计画布用色（给 AI 当上下文，也给色值库用）
function ops.colorUsage(img, maxColors)
  if img.bytesPerPixel ~= 4 then return {}, 0 end
  maxColors = maxColors or 12
  local src = img.bytes
  local stride = img.rowStride
  local counts, total, opaque = {}, 0, 0
  for y = 0, img.height - 1 do
    local rowBase = y * stride
    for x = 0, img.width - 1 do
      local p = rowBase + x * 4 + 1
      local r, g, b, a = src:byte(p, p + 3)
      total = total + 1
      if a > 0 then
        opaque = opaque + 1
        local hex = util.rgbToHex(r, g, b)
        counts[hex] = (counts[hex] or 0) + 1
      end
    end
  end
  local list = {}
  for hex, n in pairs(counts) do list[#list + 1] = { hex = hex, count = n } end
  table.sort(list, function(a, b) return a.count > b.count end)
  while #list > maxColors do table.remove(list) end
  return list, total, opaque
end

return ops
