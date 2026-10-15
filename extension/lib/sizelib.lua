-- lib/sizelib.lua -- 文档级几何操作：裁剪 / 整体缩放 / 改画布尺寸 / 内容包围盒
--
-- 和 ops.lua 的分工：
--   ops.lua     改【像素】—— 在图层里画（换色、填充、描边…）
--   sizelib.lua 改【文档】—— 画布尺寸、整体重采样
--
-- "裁剪"和"整体缩放"是 AI 最容易搞混的一对，特意放一起好对照：
--   crop        切掉画布的一部分，剩下的像素原样保留（不重采样、不变形）
--   scale       画布和内容一起缩放到目标尺寸（重采样；小尺寸下会丢细节）
--   canvasSize  只改画布大小，内容尺寸不变，按锚点摆位
--
-- 相关 API（都对过 Aseprite 源码）：
--   sprite:crop(Rectangle)               sprite_class.cpp: Sprite_crop
--   app.command.SpriteSize{...}          cmd_sprite_size.cpp（method: 0=最近邻 1=双线性）
--   app.command.CanvasSize{...}          cmd_canvas_size.cpp（bounds = 新画布在旧坐标系里的位置）

local sizelib = {}

-- 逐像素扫描的上限：Lua 扫大图很慢，超了就跳过包围盒（AI 会拿到 nil 并知道原因）
local MAX_SCAN = 512

-- 内容包围盒：把所有可见图层合起来，找非透明像素的外接矩形。
-- AI 靠它判断"这张图有多少留白" —— 留白多说明该裁剪，内容铺满才该整体缩放。
-- 返回 nil, reason 表示算不出来（图太大 / 全透明 / 没文档）。
function sizelib.contentBounds(spr)
  if not spr then return nil, "no_sprite" end
  if spr.width * spr.height > MAX_SCAN * MAX_SCAN then
    return nil, "too_large"
  end

  local minX, minY, maxX, maxY = math.huge, math.huge, -1, -1
  for _, layer in ipairs(spr.layers) do
    if layer.isVisible then
      for _, cel in ipairs(layer.cels) do
        local img = cel.image
        if img and img.bytesPerPixel == 4 then
          local src = img.bytes
          local stride = img.rowStride
          local ox, oy = cel.position.x, cel.position.y
          for y = 0, img.height - 1 do
            local rowBase = y * stride
            for x = 0, img.width - 1 do
              local a = src:byte(rowBase + x * 4 + 4)   -- RGBA 的第 4 个字节
              if a and a > 0 then
                local px, py = ox + x, oy + y
                if px < minX then minX = px end
                if py < minY then minY = py end
                if px > maxX then maxX = px end
                if py > maxY then maxY = py end
              end
            end
          end
        end
      end
    end
  end

  if maxX < 0 then return nil, "empty" end
  return { x = minX, y = minY, w = maxX - minX + 1, h = maxY - minY + 1 }
end

-- 裁剪：只切画布，像素原样保留（不重采样）。
-- 区域必须落在画布内 —— 越界直接报错，让 AI 知道要先用 canvas_info 看尺寸。
function sizelib.crop(spr, x, y, w, h)
  if not spr then error("no document is open") end
  x = math.floor(tonumber(x) or 0)
  y = math.floor(tonumber(y) or 0)
  w = math.floor(tonumber(w) or 0)
  h = math.floor(tonumber(h) or 0)
  if w <= 0 or h <= 0 then error("crop width/height must be positive") end

  local cw, ch = spr.width, spr.height
  if x < 0 or y < 0 or x + w > cw or y + h > ch then
    error(string.format(
      "crop region %dx%d at (%d,%d) is outside the %dx%d canvas",
      w, h, x, y, cw, ch))
  end
  if x == 0 and y == 0 and w == cw and h == ch then
    return { changed = false, note = "the region is the whole canvas; nothing to crop" }
  end

  spr:crop(Rectangle(x, y, w, h))
  return {
    changed = true,
    op = "crop",
    from = string.format("%dx%d", cw, ch),
    to = string.format("%dx%d", w, h),
    region = { x = x, y = y, w = w, h = h },
    note = "pixels kept as-is (no resampling)",
  }
end

-- 整体缩放：画布 + 内容一起重采样到目标尺寸。
-- method: "nearest"（默认，像素画用这个）/ "bilinear"
function sizelib.scale(spr, w, h, method)
  if not spr then error("no document is open") end
  w = math.floor(tonumber(w) or 0)
  h = math.floor(tonumber(h) or 0)
  if w < 1 or h < 1 then error("target size must be at least 1x1") end

  local cw, ch = spr.width, spr.height
  if w == cw and h == ch then
    return { changed = false, note = "target size equals the current size; nothing to do" }
  end

  -- RESIZE_METHOD_NEAREST_NEIGHBOR = 0, RESIZE_METHOD_BILINEAR = 1
  -- （src/doc/algorithm/resize_image.h:22）
  local m = (method == "bilinear") and 1 or 0
  app.command.SpriteSize{
    ui = false,
    width = w,
    height = h,
    method = m,
  }

  return {
    changed = true,
    op = "scale",
    from = string.format("%dx%d", cw, ch),
    to = string.format("%dx%d", w, h),
    method = (m == 1) and "bilinear" or "nearest",
    note = "whole image resampled; fine detail may be lost when shrinking",
  }
end

-- 改画布尺寸：内容【不】缩放，按锚点摆位。
-- anchor: center（默认）/ top-left / top-right / bottom-left / bottom-right
function sizelib.canvasSize(spr, w, h, anchor)
  if not spr then error("no document is open") end
  w = math.floor(tonumber(w) or 0)
  h = math.floor(tonumber(h) or 0)
  if w < 1 or h < 1 then error("canvas size must be at least 1x1") end

  local cw, ch = spr.width, spr.height
  if w == cw and h == ch then
    return { changed = false, note = "canvas is already that size; nothing to do" }
  end

  anchor = anchor or "center"
  local dx, dy = 0, 0
  if anchor == "center" then
    dx = math.floor((cw - w) / 2)
    dy = math.floor((ch - h) / 2)
  elseif anchor == "top-left" then
    dx, dy = 0, 0
  elseif anchor == "top-right" then
    dx, dy = cw - w, 0
  elseif anchor == "bottom-left" then
    dx, dy = 0, ch - h
  elseif anchor == "bottom-right" then
    dx, dy = cw - w, ch - h
  else
    error("unknown anchor: " .. tostring(anchor) ..
          " (use center / top-left / top-right / bottom-left / bottom-right)")
  end

  app.command.CanvasSize{
    ui = false,
    bounds = Rectangle(dx, dy, w, h),
  }

  return {
    changed = true,
    op = "canvas_size",
    from = string.format("%dx%d", cw, ch),
    to = string.format("%dx%d", w, h),
    anchor = anchor,
    note = "content kept at its original size; canvas grew or shrank around it",
  }
end

return sizelib
