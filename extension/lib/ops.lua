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

-- 四舍五入并夹到 0..255（逐通道算子都要用）
local function clamp255(v)
  if v <= 0 then return 0 end
  if v >= 255 then return 255 end
  return math.floor(v + 0.5)
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

-- 自动减色：中位切分（median cut）把用色数压到 colors 以内，并同步调色板。
-- 用户明确要求过这个能力（"配色太杂，合并到 64 色以内"），所以别再回答"做不到"。
-- 透明像素不参与统计也不改；alpha 原样保留，只换 RGB。
local function op_quantize(img, o, sprite)
  local target = math.floor(tonumber(o.colors) or 64)
  if target < 2 or target > 256 then
    error("quantize: 'colors' must be between 2 and 256")
  end
  if img.bytesPerPixel ~= 4 then
    error(string.format(
      "quantize: only 32-bit RGB/RGBA layers are supported (this one is %d bytes per pixel). " ..
      "Convert with Sprite > Color Mode > RGB first.", img.bytesPerPixel))
  end
  local w, h, stride = img.width, img.height, img.rowStride
  local region = util.normRegion(o.region, w, h)
  if region.w <= 0 or region.h <= 0 then return 0, { colorsBefore = 0, colorsAfter = 0 } end
  if region.w * region.h > MAX_REGION_PIXELS then
    error(string.format("quantize: region too large: %dx%d (limit 512x512). Use a smaller region.",
      region.w, region.h))
  end

  -- 1) 直方图（只数不透明像素）
  local src = img.bytes
  local hist, colors, opaque = {}, {}, 0
  for y = region.y, region.y + region.h - 1 do
    local base = y * stride + region.x * 4 + 1
    for i = 0, region.w - 1 do
      local p = base + i * 4
      local rr, gg, bb, aa = src:byte(p, p + 3)
      if aa > 0 then
        opaque = opaque + 1
        local key = rr * 65536 + gg * 256 + bb
        local e = hist[key]
        if e then
          e.n = e.n + 1
        else
          e = { r = rr, g = gg, b = bb, n = 1 }
          hist[key] = e
          colors[#colors + 1] = e
        end
      end
    end
  end
  local before = #colors
  local report = { colorsBefore = before, colorsAfter = before, opaque = opaque }
  if before == 0 then
    report.note = "no opaque pixels in range"
    return 0, report
  end
  if before <= target then
    report.note = "already within the target; nothing merged"
    return 0, report
  end

  -- 2) 中位切分：反复挑"像素最多且还能切"的盒子，沿最宽通道按像素数二分
  local function makeBox(list)
    local box = { list = list, n = 0, rmin = 255, rmax = 0, gmin = 255, gmax = 0, bmin = 255, bmax = 0 }
    for _, c in ipairs(list) do
      box.n = box.n + c.n
      if c.r < box.rmin then box.rmin = c.r end
      if c.r > box.rmax then box.rmax = c.r end
      if c.g < box.gmin then box.gmin = c.g end
      if c.g > box.gmax then box.gmax = c.g end
      if c.b < box.bmin then box.bmin = c.b end
      if c.b > box.bmax then box.bmax = c.b end
    end
    return box
  end

  local boxes = { makeBox(colors) }
  while #boxes < target do
    local bi, best = nil, 0
    for i, box in ipairs(boxes) do
      local dr, dg, db = box.rmax - box.rmin, box.gmax - box.gmin, box.bmax - box.bmin
      local ch, span
      if dr >= dg and dr >= db then ch, span = "r", dr
      elseif dg >= db then ch, span = "g", dg
      else ch, span = "b", db end
      box.ch, box.span = ch, span
      if #box.list > 1 and span > 0 and box.n > best then bi, best = i, box.n end
    end
    if not bi then break end                 -- 只剩单色盒子：切不动了（用色数本来就不足 target）
    local box = boxes[bi]
    local ch = box.ch
    table.sort(box.list, function(a, b) return a[ch] < b[ch] end)
    local half, acc, cut = box.n / 2, 0, 1
    for i = 1, #box.list - 1 do
      acc = acc + box.list[i].n
      if acc >= half then cut = i break end
    end
    if cut < 1 then cut = 1 end
    if cut > #box.list - 1 then cut = #box.list - 1 end
    local left, right = {}, {}
    for i = 1, #box.list do
      if i <= cut then left[#left + 1] = box.list[i] else right[#right + 1] = box.list[i] end
    end
    boxes[bi] = makeBox(left)
    boxes[#boxes + 1] = makeBox(right)
  end

  -- 3) 用量从多到少排（调色板里前面的就是主色），每盒取加权平均
  table.sort(boxes, function(a, b) return a.n > b.n end)
  local palette, samples = {}, {}
  for _, box in ipairs(boxes) do
    local sr, sg, sb, n = 0, 0, 0, 0
    for _, c in ipairs(box.list) do
      sr, sg, sb, n = sr + c.r * c.n, sg + c.g * c.n, sb + c.b * c.n, n + c.n
    end
    local r = math.floor(sr / n + 0.5)
    local g = math.floor(sg / n + 0.5)
    local b = math.floor(sb / n + 0.5)
    palette[#palette + 1] = { r = r, g = g, b = b }
    local packed = r * 65536 + g * 256 + b
    for _, c in ipairs(box.list) do samples[c.r * 65536 + c.g * 256 + c.b] = packed end
  end

  -- 4) 写回像素（保留 alpha）
  local changed = transform(img, region, function(x, y, r, g, b, a)
    if a == 0 then return nil end
    local v = samples[r * 65536 + g * 256 + b]
    if not v then return nil end
    local nr = math.floor(v / 65536) % 256
    local ng = math.floor(v / 256) % 256
    local nb = v % 256
    if nr == r and ng == g and nb == b then return nil end
    return nr, ng, nb, a
  end)

  -- 5) 调色板同步。设不了不算算子失败（像素已经改好了），只记一笔让模型知道
  if o.updatePalette ~= false and sprite then
    local ok, err = pcall(function()
      local pal = Palette(#palette)
      for i, c in ipairs(palette) do pal:setColor(i - 1, Color(c.r, c.g, c.b)) end
      sprite:setPalette(pal)
    end)
    if ok then
      report.paletteChanged = #palette
    else
      report.paletteNote = tostring(err)
    end
  end

  report.colorsAfter = #boxes
  report.merged = before - #boxes
  return changed, report
end

-- 锐化边缘：3x3 非锐化掩模（unsharp mask）。
-- 新值 = 原值 + amount * (原值 - 3x3 均值)。均值只统计【不透明】邻居：
-- 把透明邻居算进去的话，剪影边缘会被拉出一条灰边（这是修图工具上常见的老毛病）。
-- alpha 一律不动 —— 像素画的"锐"是 RGB 的对比，不是透明度。
-- threshold 是"忽略带"：局部差异小于它的像素不动，用来保护本来就平的地方，
-- 免得把噪点（或抖动网点的颗粒）一起放大。
local function op_sharpen(img, o)
  local amount = tonumber(o.amount) or 1.0
  if amount < 0 then error("sharpen: 'amount' must be >= 0 (1 = standard)") end
  local threshold = tonumber(o.threshold) or 0
  if threshold < 0 then threshold = 0 end
  local w, h, stride = img.width, img.height, img.rowStride
  local region = util.normRegion(o.region, w, h)
  if region.w <= 0 or region.h <= 0 then return 0 end
  if region.w * region.h > MAX_REGION_PIXELS then
    error(string.format("sharpen: region too large: %dx%d (limit 512x512). Narrow it down first.",
      region.w, region.h))
  end
  local src = img.bytes
  return transform(img, region, function(x, y, r, g, b, a)
    if a == 0 then return nil end
    local sr, sg, sb, n = 0, 0, 0, 0
    for dy = -1, 1 do
      local ny = y + dy
      if ny >= 0 and ny < h then
        for dx = -1, 1 do
          local nx = x + dx
          if nx >= 0 and nx < w then
            local p = ny * stride + nx * 4 + 1
            local nr, ng, nb, na = src:byte(p, p + 3)
            if na > 0 then
              sr, sg, sb, n = sr + nr, sg + ng, sb + nb, n + 1
            end
          end
        end
      end
    end
    if n == 0 then return nil end
    local dr, dg, db = r - sr / n, g - sg / n, b - sb / n
    if math.abs(dr) <= threshold and math.abs(dg) <= threshold and math.abs(db) <= threshold then
      return nil
    end
    local nr = clamp255(r + amount * dr)
    local ng = clamp255(g + amount * dg)
    local nb = clamp255(b + amount * db)
    if nr == r and ng == g and nb == b then return nil end
    return nr, ng, nb, a
  end)
end

-- 加强（或减弱）明暗对比：以 pivot（默认 128，中灰）为轴把每个通道乘开。
-- amount > 1 拉开、< 1 压平；只动 RGB，alpha 原样 —— 所以透明区域和剪影形状不受影响。
-- 逐通道而不是只算亮度：像素画的"立体感"多半来自同一色相的明暗档，逐通道更贴近
-- 手绘时"把暗部再压暗一档"的做法，也不会把色相整体拽偏。
local function op_contrast(img, o)
  local amount = tonumber(o.amount)
  if amount == nil then amount = 1.3 end
  if amount <= 0 then error("contrast: 'amount' must be > 0 (1 = unchanged, 1.3 = +30%)") end
  local pivot = tonumber(o.pivot) or 128
  return transform(img, o.region, function(x, y, r, g, b, a)
    if a == 0 then return nil end
    local nr = clamp255(pivot + (r - pivot) * amount)
    local ng = clamp255(pivot + (g - pivot) * amount)
    local nb = clamp255(pivot + (b - pivot) * amount)
    if nr == r and ng == g and nb == b then return nil end
    return nr, ng, nb, a
  end)
end

local OPS = {
  replace_color = { fn = op_replace_color, desc = "replace pixels of one colour with another (tolerance absorbs anti-aliased edges)" },
  erase_color   = { fn = op_erase_color,   desc = "make pixels of one colour transparent" },
  erase_region  = { fn = op_erase_region,  desc = "clear a rectangular region to transparent" },
  fill_region   = { fn = op_fill_region,   desc = "fill a rectangular region with a solid colour" },
  outline       = { fn = op_outline,       desc = "draw a 1px outline around opaque pixels, on previously transparent pixels" },
  despeckle     = { fn = op_despeckle,     desc = "delete isolated blobs up to maxCluster pixels (1 = single stray pixel)" },
  palette_map   = { fn = op_palette_map,   desc = "remap colours by { old: new } and update the palette too" },
  quantize      = { fn = op_quantize,      desc = "reduce the number of colours to N by median cut (merges similar colours); use it for \"too many colours / simplify the palette / merge to 64 colours\"; also rewrites the palette" },
  sharpen       = { fn = op_sharpen,       desc = "sharpen edges: 3x3 unsharp mask on RGB, alpha untouched; use it for \"sharpen / crisp up the edges / make it less blurry\" (amount 1 = standard, 2+ = aggressive; threshold 0-255 leaves flat areas alone)" },
  contrast      = { fn = op_contrast,      desc = "raise or lower light/dark contrast: pushes every channel away from pivot (default 128) by amount (1.3 = +30%, 1 = unchanged, 0.5 = flatter); alpha untouched; use it for \"more contrast / darker shadows, brighter highlights / flat looking\"" },
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
