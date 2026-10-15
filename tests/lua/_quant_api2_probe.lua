-- 探针 2：减色调色板 + 缩略图取图这两件事的 API 细节（无头可跑）
--
--   ASE_PROBE_OUT=out.txt aseprite -b --script tests/lua/_quant_api2_probe.lua

local out = {}
local function p(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(t, " ")
end

-- A) Palette(n) + setColor + sprite:setPalette（RGB 文档上行不行）
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  local ok, err = pcall(function()
    local pal = Palette(64)
    for i = 0, 63 do pal:setColor(i, Color((i * 4) % 256, (i * 7) % 256, (i * 11) % 256)) end
    spr:setPalette(pal)
  end)
  p("A1 Palette(64)+setColor+setPalette:", ok, ok and "" or err)
  p("A2 palette 大小:", #spr.palettes[1])
  local c = spr.palettes[1]:getColor(5)
  p("A3 第 5 号色:", string.format("#%02X%02X%02X", c.red, c.green, c.blue))

  -- 新调色板要塞进 app.transaction 才可撤销吗？这里只验证"能不能设"
  local ok2, err2 = pcall(function() spr:setPalette(Palette(16)) end)
  p("A4 再设成 16 色:", ok2, ok2 and "" or err2, "#pal=" .. tostring(#spr.palettes[1]))
end

-- B) spr:flatten() 会不会破坏文档（缩略图要拿全图）
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  local l1 = spr.layers[1]
  local l2 = spr:newLayer()
  spr:newCel(l1, 1, Image(8, 8, ColorMode.RGB), Point(0, 0))
  spr:newCel(l2, 1, Image(8, 8, ColorMode.RGB), Point(0, 0))
  p("B0 层数:", #spr.layers)
  local flat
  local ok, err = pcall(function() flat = spr:flatten() end)
  p("B1 flatten():", ok, ok and "" or err, "层数 after:", #spr.layers,
    "得到 Image:", flat ~= nil and type(flat) or "nil")
  if flat then p("B2 尺寸:", flat.width, flat.height, "bpp:", flat.bytesPerPixel) end
end

-- C) 采样读像素：(r,g,b,a) 取法 + 透明像素
do
  local img = Image(4, 4, ColorMode.RGB)
  img:putPixel(1, 1, Color(10, 20, 30))
  local stride = img.rowStride
  local p1 = stride + 1 * 4 + 1
  p("C1 bytes 读 (1,1):", img.bytes:byte(p1, p1 + 3))
  p("C2 rowStride:", stride, "width:", img.width)
  p("C3 getPixel(1,1):", string.format("0x%08X", img:getPixel(1, 1)))
end

-- D) 缩略图：给 Canvas 一个 Image（非缩放路径）能不能画 —— 只验证 drawImage(Image,x,y) 签名
do
  local src = Image(8, 8, ColorMode.RGB)
  src:putPixel(3, 3, Color(255, 0, 0))
  local dst = Image(16, 16, ColorMode.RGB)
  local ok, err = pcall(function() dst:drawImage(src, 4, 4) end)
  p("D1 drawImage(img,x,y):", ok, ok and "" or err)
  p("D2 目标 (7,7) 收到:", string.format("0x%08X", dst:getPixel(7, 7)), " (0,0):",
    string.format("0x%08X", dst:getPixel(0, 0)))
end

local f = io.open(os.getenv("ASE_PROBE_OUT") or "/tmp/_quant_api2_probe.out", "w")
f:write(table.concat(out, "\n") .. "\n")
f:close()
