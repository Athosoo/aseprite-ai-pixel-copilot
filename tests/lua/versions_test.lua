-- tests/lua/versions_test.lua -- 快照/回滚 无头测试
-- 跑法： "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/versions_test.lua
--
-- 注意（重要）：versions.rollback 内部用 `cel.image = 新图像` 写回，这会让
-- 之前持有的 image 变量失效（"Tried to access a deleted 'ImageObj'"）。
-- 所以回滚/撤销之后必须重新取 cel.image。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local versions = require("lib.versions")

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

local RED, GREEN, BLUE = Color(255, 0, 0), Color(0, 255, 0), Color(0, 0, 255)

print("== versions: 基本快照与回滚 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local cel = app.activeCel

  cel.image:clear(Rectangle(0, 0, 8, 8), RED)
  local v1 = versions.push("初始红底", spr)
  check("快照返回 id=1", v1.id == 1, v1.id)
  check("快照记录了日期", v1.date ~= nil and #v1.date > 0, v1.date)
  check("快照落盘", v1.file ~= nil and app.fs.isFile(v1.file), v1.file)

  cel.image:clear(Rectangle(0, 0, 8, 8), GREEN)
  local v2 = versions.push("改成绿底", spr)
  check("第二个快照 id=2", v2.id == 2, v2.id)

  local list = versions.list(spr)
  check("版本栈有 2 条", #list == 2, #list)
  check("最后一条标记 isLast", list[2].isLast == true)

  check("当前是绿色", cel.image:getPixel(0, 0) == GREEN.rgbaPixel)

  local rep = versions.rollback(1, spr)
  check("回滚匹配了 1 个 cel", rep.matched == 1 and rep.total == 1, rep.matched .. "/" .. rep.total)
  check("回滚后是红色", cel.image:getPixel(0, 0) == RED.rgbaPixel,
    string.format("%08X", cel.image:getPixel(0, 0)))
  check("回滚标签带版本名", rep.label == "初始红底", rep.label)

  app.undo()
  check("回滚本身可撤销（退回绿色）", cel.image:getPixel(0, 0) == GREEN.rgbaPixel,
    string.format("%08X", cel.image:getPixel(0, 0)))
  app.redo()

  versions.rollback("last", spr)
  check("rollback('last') 回到最近快照（绿）", cel.image:getPixel(0, 0) == GREEN.rgbaPixel,
    string.format("%08X", cel.image:getPixel(0, 0)))
end

print("== versions: 多图层 + 调色板 ==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local layer2 = spr:newLayer()
  spr:newCel(layer2, 1)
  local l1, l2 = spr.layers[1], spr.layers[2]
  l1:cel(1).image:clear(Rectangle(0, 0, 4, 4), RED)
  l2:cel(1).image:clear(Rectangle(0, 0, 4, 4), BLUE)
  spr.palettes[1]:setColor(0, Color(255, 0, 0))

  versions.push("两层", spr)

  l1:cel(1).image:clear(Rectangle(0, 0, 4, 4), GREEN)
  l2:cel(1).image:clear(Rectangle(0, 0, 4, 4), GREEN)
  spr.palettes[1]:setColor(0, Color(1, 2, 3))

  local rep = versions.rollback(1, spr)
  check("两个图层都还原", rep.matched == 2, rep.matched)
  check("图层1 回到红", l1:cel(1).image:getPixel(0, 0) == RED.rgbaPixel)
  check("图层2 回到蓝", l2:cel(1).image:getPixel(0, 0) == BLUE.rgbaPixel)
  local c0 = spr.palettes[1]:getColor(0)
  check("调色板还原", c0.red == 255 and c0.green == 0 and c0.blue == 0,
    string.format("%d,%d,%d", c0.red, c0.green, c0.blue))
end

print("== versions: cel 位置 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local cel = app.activeCel
  cel.image:clear(Rectangle(0, 0, 8, 8), RED)
  cel.position = Point(2, 3)
  versions.push("带偏移", spr)
  cel.position = Point(0, 0)
  cel.image:clear(Rectangle(0, 0, 8, 8), GREEN)

  versions.rollback(1, spr)
  check("cel 位置还原", cel.position.x == 2 and cel.position.y == 3,
    cel.position.x .. "," .. cel.position.y)
  check("像素还原", cel.image:getPixel(0, 0) == RED.rgbaPixel)
end

print("== versions: 图层缺失时不崩 ==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local l2 = spr:newLayer()
  spr:newCel(l2, 1)
  versions.push("两层", spr)
  spr:deleteLayer(spr.layers[2])
  local rep = versions.rollback(1, spr)
  check("只还原存在的图层", rep.matched == 1 and #rep.missing == 1, rep.matched .. "/" .. #rep.missing)
end

print("== versions: 错误处理 ==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local ok, err = pcall(function() versions.rollback(nil, spr) end)
  check("没有快照时报错", not ok, err)
end

print(string.format("\n==== versions_test: %d 通过, %d 失败 ====", passes, fails))
if fails > 0 then error(fails .. " 个断言失败") end
