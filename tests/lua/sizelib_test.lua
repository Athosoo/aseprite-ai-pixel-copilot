-- tests/lua/sizelib_test.lua -- 文档级几何操作的无头测试
--
-- 跑法： 在仓库根执行
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/sizelib_test.lua
--
-- 覆盖：内容包围盒、裁剪、整体缩放、改画布尺寸、越界保护。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end   -- 从仓库根跑即可
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local sizelib = require("lib.sizelib")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra and ("  <- " .. tostring(extra)) or ""))
  end
end

-- 造一张 w x h 的画布，在 (rx,ry) 处画 rw x rh 的不透明实心块，其余留空
local function makeSprite(w, h, rx, ry, rw, rh)
  local spr = Sprite(w, h, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  img:clear(Rectangle(0, 0, w, h), Color(0, 0, 0, 0))
  if rw and rh then
    img:clear(Rectangle(rx, ry, rw, rh), Color(255, 0, 0, 255))
  end
  return spr
end

print("== sizelib: 内容包围盒 ==")
do
  local spr = makeSprite(32, 32, 8, 12, 10, 6)
  local b, why = sizelib.contentBounds(spr)
  ok(b ~= nil, "能算出包围盒", why)
  if b then
    ok(b.x == 8 and b.y == 12, "左上角 = (8,12)，实际 (" .. b.x .. "," .. b.y .. ")")
    ok(b.w == 10 and b.h == 6, "尺寸 = 10x6，实际 " .. b.w .. "x" .. b.h)
  end
end

do
  local spr = makeSprite(16, 16, nil, nil, nil, nil)   -- 全透明
  local b, why = sizelib.contentBounds(spr)
  ok(b == nil and why == "empty", "全透明 -> empty，实际 " .. tostring(why))
end

print("== sizelib: 裁剪（像素不变）==")
do
  local spr = makeSprite(64, 64, 10, 10, 20, 20)
  local before = app.activeCel.image:getPixel(15, 15)
  local res = sizelib.crop(spr, 8, 8, 32, 32)
  ok(res.changed == true, "裁剪生效")
  ok(spr.width == 32 and spr.height == 32, "画布变成 32x32，实际 " .. spr.width .. "x" .. spr.height)
  -- crop 只挪 cel.position（实测变成 -8,-8），image 内容原封不动 ——
  -- 所以在同一局部坐标上读，值必须一样，这才叫"没重采样"
  local after = app.activeCel.image:getPixel(15, 15)
  ok(before == after, "image 内容原封不动（crop 不重采样）")
  ok(app.activeCel.position.x == -8, "cel 被挪到 -8（靠 position 实现裁剪），实际 " .. app.activeCel.position.x)
end

do
  local spr = makeSprite(32, 32, 4, 4, 8, 8)
  local okCall, err = pcall(sizelib.crop, spr, 20, 20, 20, 20)
  ok(not okCall, "越界裁剪被拒绝")
  ok(tostring(err):find("outside") ~= nil, "错误信息说明了越界", err)
  ok(spr.width == 32, "失败后画布尺寸未变")
end

do
  local spr = makeSprite(16, 16, 2, 2, 4, 4)
  local res = sizelib.crop(spr, 0, 0, 16, 16)
  ok(res.changed == false, "整幅 = 无操作")
end

print("== sizelib: 整体缩放 ==")
do
  local spr = makeSprite(64, 64, 10, 10, 20, 20)
  local res = sizelib.scale(spr, 32, 32, "nearest")
  ok(res.changed == true, "缩放生效")
  ok(spr.width == 32 and spr.height == 32, "画布变成 32x32，实际 " .. spr.width .. "x" .. spr.height)
  ok(res.method == "nearest", "方法 = nearest，实际 " .. tostring(res.method))
end

do
  local spr = makeSprite(32, 32, 8, 8, 8, 8)
  local res = sizelib.scale(spr, 32, 32)
  ok(res.changed == false, "同尺寸 = 无操作")
end

print("== sizelib: 改画布尺寸（内容不缩放）==")
do
  local spr = makeSprite(16, 16, 4, 4, 8, 8)
  local before = app.activeCel.image:getPixel(4, 4)
  local res = sizelib.canvasSize(spr, 32, 32, "center")
  ok(res.changed == true, "改尺寸生效")
  ok(spr.width == 32 and spr.height == 32, "画布 32x32，实际 " .. spr.width .. "x" .. spr.height)
  -- 同样：canvasSize 也不碰 image，只挪 cel.position（居中 -> +8,+8）
  local after = app.activeCel.image:getPixel(4, 4)
  ok(before == after, "image 内容原封不动（canvasSize 不缩放内容）")
  ok(app.activeCel.position.x == 8, "cel 被挪到 +8（居中），实际 " .. app.activeCel.position.x)
end

do
  local spr = makeSprite(16, 16, 4, 4, 8, 8)
  local okCall, err = pcall(sizelib.canvasSize, spr, 32, 32, "middle")
  ok(not okCall, "未知锚点被拒绝")
  ok(tostring(err):find("unknown anchor") ~= nil, "错误信息说明了锚点问题", err)
end

do
  local spr = makeSprite(16, 16, 4, 4, 8, 8)
  local res = sizelib.canvasSize(spr, 16, 16)
  ok(res.changed == false, "同尺寸 = 无操作")
end

print(string.format("%d passed, %d failed", pass, fail))
