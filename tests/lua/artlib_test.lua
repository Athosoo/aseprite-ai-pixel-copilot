-- tests/lua/artlib_test.lua -- 字符网格作画的无头测试
--
-- 跑法： 在仓库根执行
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/artlib_test.lua
--
-- 重点验：字符->像素的映射对不对、写歪的行会不会被挡、调色板缺字符会不会被挡、
-- 出界像素是不是"跳过但计数"（而不是静默丢失或直接报错）。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end   -- 从仓库根跑即可
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local artlib = require("lib.artlib")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra ~= nil and ("  <- " .. tostring(extra)) or ""))
  end
end

-- 读某个像素的 32 位值（0 = 全透明）
local function px(img, x, y) return img:getPixel(x, y) end

print("== stampGrid: 基本映射 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  img:clear(Rectangle(0, 0, 8, 8), Color(0, 0, 0, 0))

  local res = artlib.stampGrid(img,
    { "X.X",
      ".X.",
      "X.X" },
    { ["X"] = "#FF0000", ["."] = "" },
    1, 1)

  ok(res.painted == 5, "画了 5 个像素，实际 " .. res.painted)
  ok(res.width == 3 and res.height == 3, "网格 3x3，实际 " .. res.width .. "x" .. res.height)
  ok(px(img, 1, 1) ~= 0, "(1,1) 被画上了")
  ok(px(img, 2, 1) == 0, "(2,1) 是 '.' 保持透明")
  ok(px(img, 3, 1) ~= 0, "(3,1) 被画上了")
  ok(px(img, 0, 0) == 0, "偏移之外没被碰")
end

print("== stampGrid: 行宽不一致要被挡住 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  local okCall, err = pcall(artlib.stampGrid, img, { "XX", "X" }, { ["X"] = "#FF0000" }, 0, 0)
  ok(not okCall, "行宽不一致 -> 报错")
  ok(tostring(err):find("same width") ~= nil, "错误信息说清了是行宽问题", err)
end

print("== stampGrid: 调色板缺字符要被挡住 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  local okCall, err = pcall(artlib.stampGrid, img, { "XY" }, { ["X"] = "#FF0000" }, 0, 0)
  -- Y 不在调色板里 -> 查表得到 nil -> 当透明处理，不报错但也不画
  ok(okCall, "缺字符当透明处理（不炸）")
end

print("== stampGrid: 坏色值要报错 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  local okCall, err = pcall(artlib.stampGrid, img, { "X" }, { ["X"] = "not-a-color" }, 0, 0)
  ok(not okCall, "非法色值 -> 报错")
  ok(tostring(err):find("bad colour") ~= nil, "错误信息指出了色值问题", err)
end

print("== stampGrid: 出界是【跳过但计数】==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeCel.image
  img:clear(Rectangle(0, 0, 4, 4), Color(0, 0, 0, 0))
  -- 3x3 的实心块放在 (3,3)：只有 (3,3) 在画布内
  local res = artlib.stampGrid(img, { "XXX", "XXX", "XXX" }, { ["X"] = "#00FF00" }, 3, 3)
  ok(res.painted == 1, "只画进去 1 个，实际 " .. res.painted)
  ok(res.skippedOutOfBounds == 8, "跳过 8 个，实际 " .. res.skippedOutOfBounds)
  ok(px(img, 3, 3) ~= 0, "画布内的那个确实画上了")
end

print("== stampGrid: 空 rows 报错 ==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local okCall, err = pcall(artlib.stampGrid, app.activeCel.image, {}, {}, 0, 0)
  ok(not okCall, "空网格 -> 报错")
end

print("== newSprite ==")
do
  local spr, info = artlib.newSprite(16, 24, "rgb")
  ok(spr ~= nil, "创建成功")
  ok(info.width == 16 and info.height == 24, "尺寸 16x24，实际 " .. info.width .. "x" .. info.height)
  ok(app.activeSprite == spr, "成了当前文档")

  local okCall, err = pcall(artlib.newSprite, 0, 10)
  ok(not okCall, "尺寸 0 -> 报错", err)
  local okCall2, err2 = pcall(artlib.newSprite, 99999, 10)
  ok(not okCall2, "超大尺寸 -> 拒绝", err2)
end

print("== addLayer ==")
do
  artlib.newSprite(8, 8, "rgb")
  local before = #app.activeSprite.layers
  local layer, info = artlib.addLayer(app.activeSprite, "阴影", { opacity = 128 })
  ok(#app.activeSprite.layers == before + 1, "图层数 +1")
  ok(info.name == "阴影", "名字对，实际 " .. tostring(info.name))
  ok(info.opacity == 128, "不透明度对，实际 " .. tostring(info.opacity))
end

print("== drawArt: 自动建层 + 一个撤销步骤 ==")
do
  artlib.newSprite(16, 16, "rgb")
  local spr = app.activeSprite
  local names = {}
  for _, l in ipairs(spr.layers) do names[#names + 1] = l.name end

  local res = artlib.drawArt(spr, {
    layer = "主体",
    palette = { ["#"] = "#2E86DE", ["."] = "" },
    rows = { ".##.", "####", ".##." },
  })

  ok(res.painted == 8, "画了 8 个像素，实际 " .. res.painted)
  ok(res.layer == "主体", "落到指定图层，实际 " .. tostring(res.layer))

  local found = false
  for _, l in ipairs(spr.layers) do if l.name == "主体" then found = true end end
  ok(found, "图层不存在时被自动创建")

  -- 再画一次到同一图层，不应该再建一层
  local n1 = #spr.layers
  artlib.drawArt(spr, { layer = "主体", palette = { ["#"] = "#FF0000" }, rows = { "#" } })
  ok(#spr.layers == n1, "同名图层复用，没有重复创建")
end

print("== drawArt: 指定偏移 ==")
do
  artlib.newSprite(8, 8, "rgb")
  local spr = app.activeSprite
  artlib.drawArt(spr, {
    layer = "L", palette = { ["X"] = "#FFFFFF" }, rows = { "X" }, x = 5, y = 6,
  })
  local cel = nil
  for _, l in ipairs(spr.layers) do if l.name == "L" then cel = l:cel(1) end end
  ok(cel ~= nil, "找到图层 L 的 cel")
  if cel then
    ok(cel.image:getPixel(5, 6) ~= 0, "画在 (5,6)")
    ok(cel.image:getPixel(0, 0) == 0, "(0,0) 没被碰")
  end
end

print("== 非 ASCII 像素字符（模型很爱用方块字符）==")
do
  -- 这一组是回归测试：stampGrid 原来按【字节】切行，一个 3 字节的字符被切成
  -- 三个半字符，一个都匹配不上调色板 -> painted=0 但报成功，模型反复重画到步数耗尽。
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  local img = app.activeSprite.cels[1].image

  local cases = {
    { "方块字符", { "██..", ".██.", "..██" }, { ["."] = "", ["█"] = "#FF0000", ["▒"] = "#00FF00" }, 6 },
    { "全角汉字", { "口口..", ".口口." }, { ["."] = "", ["口"] = "#FF0000", ["田"] = "#00FF00" }, 4 },
    { "混排中英", { "X口.X", "口X口." }, { ["."] = "", X = "#FF0000", ["口"] = "#00FF00" }, 6 },
  }
  for _, c in ipairs(cases) do
    local res = artlib.stampGrid(img, c[2], c[3], 0, 0)
    ok(res.painted == c[4], string.format("%s：画了 %d 个（期望 %d）", c[1], res.painted, c[4]))
    -- 宽度必须是【字符数】，不是字节数
    ok(res.width == #(function()
      local t = {}
      for _, code in utf8.codes(c[2][1]) do t[#t + 1] = utf8.char(code) end
      return t
    end)(), string.format("%s：宽度按字符算（%d）", c[1], res.width))
  end

  -- 行宽校验也要按字符数：3 个方块字符 + 1 个点 = 4 个字符
  ok(pcall(function() artlib.stampGrid(img, { "███.", "██." }, {}, 0, 0) end) == false,
    "非 ASCII 行宽不一致仍然报错")
end

print("== 全透明网格：painted=0 且能说清为什么 ==")
do
  local spr = Sprite(4, 4, ColorMode.RGB)
  app.activeSprite = spr
  local img = spr.cels[1].image
  local res = artlib.stampGrid(img, { "..", ".." }, { ["."] = "" }, 0, 0)
  ok(res.painted == 0, "没有像素被画上")
  ok(res.transparent == 4, "透明格子计数 = 4，实际 " .. tostring(res.transparent))
  ok(res.transparentChars ~= nil and res.transparentChars["."] == 4,
    "透明字符统计里有 '.' × 4")
end


print(string.format("%d passed, %d failed", pass, fail))
