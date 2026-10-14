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

print(string.format("\n==== ops_test: %d 通过, %d 失败 ====", passes, fails))
if fails > 0 then error(fails .. " 个断言失败") end
