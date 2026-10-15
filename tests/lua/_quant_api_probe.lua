-- 探针：减色 + 缩略图要用到的三个 API 到底行不行（无头可跑）
--
--   ASE_PROBE_OUT=out.txt aseprite -b --script tests/lua/_quant_api_probe.lua

local out = {}
local function p(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(t, " ")
end

-- A) RGB sprite 上能不能直接换整块调色板
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  p("A0 palette size before:", #spr.palettes[1])
  local colors = {}
  for i = 1, 64 do colors[i] = Color((i * 3) % 255, (i * 7) % 255, (i * 11) % 255) end
  local ok, err = pcall(function() spr:setPalette(Palette(colors)) end)
  p("A1 setPalette(Palette(64 colors)):", ok, ok and "" or err)
  p("A2 palette size after:", #spr.palettes[1])

  -- 换完之后还能不能正常存/导出（怕的是 sprite 变得不一致）
  local ok2, err2 = pcall(function() spr:newCel(spr.layers[1], 1, Image(8, 8, ColorMode.RGB), Point(0, 0)) end)
  p("A3 换调色板后还能加 cel:", ok2, ok2 and "" or err2)
end

-- B) Image:drawImage(src, dstRect) 会不会【缩放】
do
  local src = Image(16, 16, ColorMode.RGB)
  for y = 0, 15 do
    for x = 0, 15 do src:putPixel(x, y, Color(x * 15, y * 15, 128)) end
  end
  local dst = Image(64, 64, ColorMode.RGB)
  local ok, err = pcall(function() dst:drawImage(src, Rectangle(0, 0, 16, 16), Rectangle(0, 0, 64, 64)) end)
  p("B1 Image:drawImage(srcRect,dstRect):", ok, ok and "" or err)
  -- 放大后右下角应该被填上（= 真的缩放了），而不是留透明
  local px = dst:getPixel(63, 63)
  local mid = dst:getPixel(32, 32)
  p("B2 放大后 (63,63) 打包值:", string.format("0x%08X", px), " (32,32):", string.format("0x%08X", mid))
  local filled = 0
  for y = 0, 63 do for x = 0, 63 do if dst:getPixel(x, y) ~= 0 then filled = filled + 1 end end end
  p("B3 目标图里非空像素数（64x64=4096 才算真缩放）:", filled)
end

-- C) pixels() 迭代器能不能读 + 写
do
  local img = Image(4, 4, ColorMode.RGB)
  img:putPixel(0, 0, Color(1, 2, 3))
  local first, wrote = nil, 0
  local ok, err = pcall(function()
    for it in img:pixels() do
      local v = it()
      if first == nil then first = v end
      if v ~= 0 then wrote = wrote + 1 end
      it(0x0000FFFF)     -- 写回（0xAABBGGRR，红）
    end
  end)
  p("C1 pixels() 遍历+写:", ok, ok and "" or err, "首个值:", string.format("0x%08X", first or 0), "被写像素:", wrote)
  p("C2 写完 getPixel(0,0):", string.format("0x%08X", img:getPixel(0, 0)))
end

-- D) 反复 putPixel 的性能量级（缩略图按需采样时要估时间）
do
  local img = Image(256, 256, ColorMode.RGB)
  local t0 = os.clock()
  for y = 0, 63 do
    for x = 0, 63 do
      local sx, sy = x * 4, y * 4
      img:putPixel(x, y, img:getPixel(sx, sy))
    end
  end
  p("D1 64x64 采样写回耗时(秒):", string.format("%.3f", os.clock() - t0))
end

local f = io.open(os.getenv("ASE_PROBE_OUT") or "/tmp/_quant_api_probe.out", "w")
f:write(table.concat(out, "\n") .. "\n")
f:close()
