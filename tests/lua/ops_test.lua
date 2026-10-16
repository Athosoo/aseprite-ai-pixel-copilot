-- tests/lua/ops_test.lua -- 算子无头测试
-- 跑法： "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/ops_test.lua

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local ops = require("lib.ops")

local fails, passes = 0, 0
local function check(name, cond, extra)
  if cond then
    passes = passes + 1
    print("  ok   " .. name)
  else
    fails = fails + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end

local RED     = Color(255, 0, 0)
local GREEN   = Color(0, 255, 0)
local BLUE    = Color(0, 0, 255)
local CLEAR   = Color(0, 0, 0, 0)
local OUTLINE = Color(10, 20, 30)

-- 新建 8x8 sprite，返回 sprite, cel, image
local function newSprite()
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local cel = app.activeCel
  return spr, cel, cel.image
end

local function px(img, x, y)
  return img:getPixel(x, y)
end

local function countOpaque(img)
  local n = 0
  for y = 0, img.height - 1 do
    for x = 0, img.width - 1 do
      if (px(img, x, y) >> 24) & 0xFF ~= 0 then n = n + 1 end
    end
  end
  return n
end

print("== ops: replace_color ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  img:clear(Rectangle(2, 2, 2, 2), BLUE)
  local rep = ops.run({ { op = "replace_color", from = "#FF0000", to = "#00FF00" } }, "test", cel)
  check("返回报告含 changed 计数", rep.ops[1].changed == 60, rep.ops[1].changed)
  check("原红像素变绿", px(img, 0, 0) == GREEN.rgbaPixel)
  check("蓝方块未受影响", px(img, 2, 2) == BLUE.rgbaPixel)
  app.undo()
  check("undo 还原红色", px(img, 0, 0) == RED.rgbaPixel)
end

print("== ops: replace_color 限定区域 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  ops.run({ { op = "replace_color", from = "#FF0000", to = "#00FF00",
              region = { x = 0, y = 0, w = 2, h = 2 } } }, "test", cel)
  check("区域内变色", px(img, 0, 0) == GREEN.rgbaPixel)
  check("区域外未变", px(img, 3, 3) == RED.rgbaPixel)
end

print("== ops: erase_color ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  img:clear(Rectangle(0, 0, 2, 2), BLUE)
  ops.run({ { op = "erase_color", color = "#0000FF" } }, "test", cel)
  check("蓝被擦成透明", px(img, 0, 0) == CLEAR.rgbaPixel, string.format("%08X", px(img, 0, 0)))
  check("红还在", px(img, 5, 5) == RED.rgbaPixel)
end

print("== ops: fill_region / erase_region ==")
do
  local spr, cel, img = newSprite()
  ops.run({
    { op = "fill_region", color = "#0000FF", region = { x = 1, y = 1, w = 3, h = 3 } },
    { op = "erase_region", region = { x = 0, y = 0, w = 1, h = 1 } },
  }, "test", cel)
  check("填充生效", px(img, 2, 2) == BLUE.rgbaPixel)
  check("区域外仍透明", px(img, 6, 6) == CLEAR.rgbaPixel)
  check("擦除的是空区域（未误伤）", px(img, 1, 1) == BLUE.rgbaPixel)
end

print("== ops: outline ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(3, 3, 2, 2), RED)
  ops.run({ { op = "outline", color = "#0A141E" } }, "test", cel)
  check("中心未被覆盖", px(img, 3, 3) == RED.rgbaPixel)
  check("上方描边", px(img, 3, 2) == OUTLINE.rgbaPixel, string.format("%08X", px(img, 3, 2)))
  check("左侧描边", px(img, 2, 3) == OUTLINE.rgbaPixel)
  check("斜角不描（4 连通）", px(img, 2, 2) == CLEAR.rgbaPixel)
  check("不透明像素总数 = 4 + 8", countOpaque(img) == 12, countOpaque(img))
end

print("== ops: despeckle ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(2, 2, 3, 3), RED)  -- 3x3 主体
  img:clear(Rectangle(7, 0, 1, 1), RED)  -- 孤立点
  img:clear(Rectangle(0, 7, 1, 1), RED)  -- 孤立点
  img:clear(Rectangle(6, 6, 1, 2), RED)  -- 2 像素小簇
  ops.run({ { op = "despeckle", maxCluster = 1 } }, "test", cel)
  check("孤立点被清除 (7,0)", px(img, 7, 0) == CLEAR.rgbaPixel)
  check("孤立点被清除 (0,7)", px(img, 0, 7) == CLEAR.rgbaPixel)
  check("2 像素簇保留", px(img, 6, 6) == RED.rgbaPixel)
  check("主体保留", px(img, 3, 3) == RED.rgbaPixel)
  ops.run({ { op = "despeckle", maxCluster = 2 } }, "test", cel)
  check("maxCluster=2 时 2 像素簇被清", px(img, 6, 6) == CLEAR.rgbaPixel)
  check("主体仍在", countOpaque(img) == 9, countOpaque(img))
end

print("== ops: palette_map ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  local pal = spr.palettes[1]
  pal:setColor(0, Color(255, 0, 0))
  ops.run({ { op = "palette_map", map = { ["#FF0000"] = "#00FF00" } } }, "test", cel)
  check("像素换色", px(img, 0, 0) == GREEN.rgbaPixel)
  local c0 = pal:getColor(0)
  check("调色板条目同步", c0.red == 0 and c0.green == 255 and c0.blue == 0,
    string.format("%d,%d,%d", c0.red, c0.green, c0.blue))
end

print("== ops: 错误处理与事务原子性 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  local ok, err = pcall(function()
    ops.run({
      { op = "fill_region", color = "#0000FF", region = { x = 0, y = 0, w = 2, h = 2 } },
      { op = "no_such_op" },
    }, "test", cel)
  end)
  check("未知算子报错", not ok, err)
  check("报错后整批未提交（像素未变）", px(img, 0, 0) == RED.rgbaPixel,
    string.format("%08X", px(img, 0, 0)))

  local ok2, err2 = pcall(function()
    ops.run({ { op = "replace_color", from = "notacolor", to = "#00FF00" } }, "test", cel)
  end)
  check("非法颜色报错", not ok2, err2)
end

print("== ops: colorUsage ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  img:clear(Rectangle(0, 0, 2, 2), BLUE)
  local list, total, opaque = ops.colorUsage(img)
  check("总像素 64", total == 64, total)
  check("不透明 64", opaque == 64, opaque)
  check("统计出 2 种颜色", #list == 2, #list)
  check("最多的是红 60", list[1].hex == "#FF0000" and list[1].count == 60, list[1].hex .. ":" .. list[1].count)
end

print("== ops: quantize（自动减色，用户实测提的那条）==")
do
  -- 造一张"配色很杂"的图：8x8 共 64 个互不相同的颜色
  local spr, cel, img = newSprite()
  for y = 0, 7 do
    for x = 0, 7 do
      img:putPixel(x, y, Color(x * 32 + 3, y * 32 + 5, (x + y) * 16 + 7))
    end
  end
  check("起始用色 = 64", #ops.colorUsage(img, 99) == 64, #ops.colorUsage(img, 99))

  -- 合并到 8 色以内
  local rep = ops.run({ { op = "quantize", colors = 8 } }, "减色", cel)
  local q = rep.ops[1].extra
  check("报告里写了原始色数", q.colorsBefore == 64, q.colorsBefore)
  check("报告里写了目标色数", q.colorsAfter <= 8 and q.colorsAfter > 1, q.colorsAfter)
  check("报告里写了合并了多少", q.merged == 64 - q.colorsAfter, q.merged)
  check("确实改了像素", rep.ops[1].changed == 64, rep.ops[1].changed)

  -- 真正落地的颜色数（不是只看报告）
  local after = #ops.colorUsage(img, 99)
  check("画布上实际只剩 <=8 色", after <= 8 and after > 1, after)
  check("调色板也同步了", q.paletteChanged == q.colorsAfter, q.paletteChanged)
  check("sprite 调色板大小 = 合并后的色数", #spr.palettes[1] == q.colorsAfter, #spr.palettes[1])
  check("调色板里真有这些颜色（不是全黑）", (function()
    local c = spr.palettes[1]:getColor(0)
    return c.red + c.green + c.blue > 0
  end)())

  -- 颜色数本来就少于目标 -> 什么都不做
  local rep2 = ops.run({ { op = "quantize", colors = 200 } }, "无操作", cel)
  check("已经够少时报 0 改动", rep2.ops[1].changed == 0, rep2.ops[1].changed)
  check("并说明原因", tostring(rep2.ops[1].extra.note):find("already") ~= nil, rep2.ops[1].extra.note)

  -- 参数校验
  local ok, err = pcall(function() ops.run({ { op = "quantize", colors = 1 } }, "坏参数", cel) end)
  check("colors=1 被拒绝", not ok and tostring(err):find("2 and 256") ~= nil, err)
  local ok2, err2 = pcall(function() ops.run({ { op = "quantize", colors = 999 } }, "坏参数", cel) end)
  check("colors=999 被拒绝", not ok2, err2)

  -- 全透明图：不炸，报告说明
  local spr3, cel3, img3 = newSprite()
  img3:clear(Rectangle(0, 0, 8, 8), CLEAR)
  local rep3 = ops.run({ { op = "quantize", colors = 8 } }, "空图", cel3)
  check("全透明图不报错且 0 改动", rep3.ops[1].changed == 0, rep3.ops[1].changed)
  check("全透明图给了说明", tostring(rep3.ops[1].extra.note):find("no opaque") ~= nil,
    rep3.ops[1].extra.note)

  -- 透明像素不参与，也不被改
  local spr5, cel5, img5 = newSprite()
  for y = 0, 7 do for x = 0, 7 do img5:putPixel(x, y, Color(x * 30 + 1, y * 30 + 2, 9)) end end
  img5:putPixel(0, 0, CLEAR)
  ops.run({ { op = "quantize", colors = 4 } }, "带透明", cel5)
  check("透明像素保持透明", img5:getPixel(0, 0) == CLEAR.rgbaPixel,
    string.format("%08X", img5:getPixel(0, 0)))

  -- 只在指定区域内减色（区域外不动）
  local spr4, cel4, img4 = newSprite()
  for y = 0, 7 do for x = 0, 7 do img4:putPixel(x, y, Color(x * 30 + 1, y * 30 + 2, 9)) end end
  local outsideBefore = img4:getPixel(7, 7)
  ops.run({ { op = "quantize", colors = 2, region = { x = 0, y = 0, w = 4, h = 4 } } }, "局部", cel4)
  check("区域外像素没动", img4:getPixel(7, 7) == outsideBefore,
    string.format("%08X -> %08X", outsideBefore, img4:getPixel(7, 7)))
  check("区域内确实合并了", #ops.colorUsage(img4, 99) < 64, #ops.colorUsage(img4, 99))
end

print("== ops: quantize 的实际效果（减色后仍看得出结构）==")
do
  -- "四个纯色 + 每个像素有微扰"模拟一张配色杂的像素画
  local spr, cel, img = newSprite()
  local base = { { 200, 30, 40 }, { 40, 180, 80 }, { 50, 80, 200 }, { 240, 220, 120 } }
  for y = 0, 7 do
    for x = 0, 7 do
      local b = base[(x % 2) + (y % 2) * 2 + 1]
      img:putPixel(x, y, Color(b[1] + x, b[2] + y, b[3] + (x * y) % 20))
    end
  end
  ops.run({ { op = "quantize", colors = 4 } }, "减到四色", cel)
  local after = #ops.colorUsage(img, 99)
  check("合并到 4 色", after == 4, after)

  -- 原来那 4 个基色附近应该各有代表色（纯色不该被并到别的色系去）
  local list = ops.colorUsage(img, 99)
  local function nearest(r, g, b)
    local best, bestD = nil, 1e9
    for _, e in ipairs(list) do
      local er = tonumber(e.hex:sub(2, 3), 16)
      local eg = tonumber(e.hex:sub(4, 5), 16)
      local eb = tonumber(e.hex:sub(6, 7), 16)
      local d = (er - r) ^ 2 + (eg - g) ^ 2 + (eb - b) ^ 2
      if d < bestD then best, bestD = e.hex, d end
    end
    return best, bestD
  end
  local hex, dist = nearest(200, 30, 40)
  check("红色系有对应代表色（没被并到别的色系）", dist < 40000, hex .. " d=" .. tostring(dist))
  local hex2, dist2 = nearest(50, 80, 200)
  check("蓝色系也有对应代表色", dist2 < 40000, hex2 .. " d=" .. tostring(dist2))
end

print("== ops: sharpen（锐化边缘）==")
do
  -- 一条竖直边界：左半 100、右半 160。边界两侧的 9 格均值分别是 120 / 140，
  -- 所以"暗的更暗、亮的更亮"能算出确切数字，不用靠肉眼看截图。
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  img:clear(Rectangle(4, 0, 4, 8), Color(160, 160, 160))
  local rep = ops.run({ { op = "sharpen" } }, "锐化", cel)
  check("只有边界那两列被改（16 像素）", rep.ops[1].changed == 16, rep.ops[1].changed)
  check("暗侧更暗 100 -> 80", px(img, 3, 4) == Color(80, 80, 80).rgbaPixel,
    string.format("%08X", px(img, 3, 4)))
  check("亮侧更亮 160 -> 180", px(img, 4, 4) == Color(180, 180, 180).rgbaPixel,
    string.format("%08X", px(img, 4, 4)))
  check("画布边界处同样算得出来（没越界崩）", px(img, 3, 0) == Color(80, 80, 80).rgbaPixel,
    string.format("%08X", px(img, 3, 0)))
  check("离边界远的地方一点没动", px(img, 0, 0) == Color(100, 100, 100).rgbaPixel)
  app.undo()
  check("undo 一步还原（整批一个撤销步）", px(img, 3, 4) == Color(100, 100, 100).rgbaPixel)
end

print("== ops: sharpen 平色不动 / amount=0 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), RED)
  local rep = ops.run({ { op = "sharpen", amount = 3 } }, "平色", cel)
  check("纯色图 0 改动", rep.ops[1].changed == 0, rep.ops[1].changed)

  local spr2, cel2, img2 = newSprite()
  img2:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  img2:clear(Rectangle(4, 0, 4, 8), Color(160, 160, 160))
  local rep2 = ops.run({ { op = "sharpen", amount = 0 } }, "零强度", cel2)
  check("amount=0 等于不动", rep2.ops[1].changed == 0, rep2.ops[1].changed)
end

print("== ops: sharpen threshold 保护平缓处 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  img:clear(Rectangle(4, 0, 4, 8), Color(160, 160, 160))
  local rep = ops.run({ { op = "sharpen", threshold = 25 } }, "忽略带", cel)
  check("差异 20 <= threshold 25：一个像素都不动", rep.ops[1].changed == 0, rep.ops[1].changed)
end

print("== ops: sharpen 不把剪影边缘拉成灰边 ==")
do
  -- 透明邻居【不参与】均值。算进去的话贴边那一列会被当成"和黑色相邻"而整体提亮，
  -- 在透明背景上就是一圈脏边 —— 像素画里这是最显眼的毛病。
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), CLEAR)
  img:clear(Rectangle(0, 0, 4, 8), Color(90, 90, 90))
  ops.run({ { op = "sharpen", amount = 3 } }, "剪影", cel)
  check("贴边的内侧像素保持原色", px(img, 3, 4) == Color(90, 90, 90).rgbaPixel,
    string.format("%08X", px(img, 3, 4)))
  check("透明区还是透明", px(img, 7, 7) == CLEAR.rgbaPixel, string.format("%08X", px(img, 7, 7)))
end

print("== ops: contrast（加强明暗对比）==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  img:clear(Rectangle(4, 0, 4, 8), Color(160, 160, 160))
  local rep = ops.run({ { op = "contrast" } }, "对比", cel)
  check("默认 1.3 把 64 个像素全改了", rep.ops[1].changed == 64, rep.ops[1].changed)
  check("暗部 100 -> 92", px(img, 0, 0) == Color(92, 92, 92).rgbaPixel,
    string.format("%08X", px(img, 0, 0)))
  check("亮部 160 -> 170", px(img, 7, 7) == Color(170, 170, 170).rgbaPixel,
    string.format("%08X", px(img, 7, 7)))
end

print("== ops: contrast 轴心 / 夹值 / 减弱 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(128, 128, 128))
  local rep = ops.run({ { op = "contrast", amount = 2 } }, "中灰", cel)
  check("128 是轴心，乘多少都不动", rep.ops[1].changed == 0, rep.ops[1].changed)

  local spr2, cel2, img2 = newSprite()
  img2:clear(Rectangle(0, 0, 8, 8), Color(250, 5, 128))
  ops.run({ { op = "contrast", amount = 3 } }, "夹值", cel2)
  check("超上限夹 255、低于下限夹 0、轴心不动",
    px(img2, 0, 0) == Color(255, 0, 128).rgbaPixel, string.format("%08X", px(img2, 0, 0)))

  local spr3, cel3, img3 = newSprite()
  img3:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  ops.run({ { op = "contrast", amount = 0.5 } }, "压平", cel3)
  check("amount<1 是压平：100 -> 114", px(img3, 0, 0) == Color(114, 114, 114).rgbaPixel,
    string.format("%08X", px(img3, 0, 0)))

  local spr4, cel4, img4 = newSprite()
  img4:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  ops.run({ { op = "contrast", amount = 2, pivot = 0 } }, "换轴心", cel4)
  check("pivot=0 时按 0 拉开：100 -> 200", px(img4, 0, 0) == Color(200, 200, 200).rgbaPixel,
    string.format("%08X", px(img4, 0, 0)))
end

print("== ops: sharpen / contrast 不动 alpha、不碰透明像素 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), CLEAR)
  img:clear(Rectangle(0, 0, 4, 8), Color(90, 90, 90, 128))
  local before = px(img, 2, 2)
  ops.run({ { op = "sharpen", amount = 2 }, { op = "contrast", amount = 2 } }, "半透明", cel)
  local after = px(img, 2, 2)
  check("RGB 被改了", after ~= before, string.format("%08X -> %08X", before, after))
  check("alpha 原样保留", (after >> 24) & 0xFF == (before >> 24) & 0xFF,
    string.format("a %d -> %d", (before >> 24) & 0xFF, (after >> 24) & 0xFF))
  check("透明像素仍是全透明", px(img, 7, 7) == CLEAR.rgbaPixel,
    string.format("%08X", px(img, 7, 7)))
end

print("== ops: sharpen / contrast 限定区域 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  ops.run({ { op = "contrast", amount = 2, region = { x = 0, y = 0, w = 4, h = 4 } } }, "局部", cel)
  check("区域内被改 100 -> 72", px(img, 0, 0) == Color(72, 72, 72).rgbaPixel,
    string.format("%08X", px(img, 0, 0)))
  check("区域外没动", px(img, 5, 5) == Color(100, 100, 100).rgbaPixel,
    string.format("%08X", px(img, 5, 5)))
end

print("== ops: 新算子的参数校验与注册 ==")
do
  local spr, cel, img = newSprite()
  img:clear(Rectangle(0, 0, 8, 8), Color(100, 100, 100))
  local ok1, err1 = pcall(function() ops.run({ { op = "contrast", amount = 0 } }, "零", cel) end)
  check("contrast amount=0 报错", not ok1, err1)
  local ok2, err2 = pcall(function() ops.run({ { op = "sharpen", amount = -1 } }, "负", cel) end)
  check("sharpen 负 amount 报错", not ok2, err2)

  local set = {}
  for _, n in ipairs(ops.names) do set[n] = true end
  check("sharpen 在注册表里", set.sharpen == true)
  check("contrast 在注册表里", set.contrast == true)
  -- 这份名单是【契约】，和 bridge/test/tools_test.mjs 的 P15 段、tools.mjs 里的
  -- apply_ops enum 必须一致：多一个（模型调了会 unknown op）、少一个（模型看不到）
  -- 都是 bug。改算子时三个地方一起改。
  local EXPECTED = {
    "contrast", "despeckle", "erase_color", "erase_region", "fill_region",
    "outline", "palette_map", "quantize", "replace_color", "sharpen",
  }
  local sorted = {}
  for _, n in ipairs(ops.names) do sorted[#sorted + 1] = n end
  table.sort(sorted)
  check("算子名单 == 契约（和 tools.mjs 的 enum 逐字相同）",
    table.concat(sorted, ",") == table.concat(EXPECTED, ","), table.concat(sorted, ","))
  local d = ops.describe()
  check("describe 里列了 sharpen", d:find("sharpen", 1, true) ~= nil)
  check("describe 里列了 contrast", d:find("contrast", 1, true) ~= nil)
end

print(string.format("\n==== ops_test: %d 通过, %d 失败 ====", passes, fails))
if fails > 0 then error(fails .. " 个断言失败") end
