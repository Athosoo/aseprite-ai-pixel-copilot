local ROOT = os.getenv("ASE_PROJ")
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"
local artlib = require("lib.artlib")

local spr = Sprite(8, 8, ColorMode.RGB)
app.activeSprite = spr

local function try(label, rows, palette)
  local ok, res = pcall(function()
    local layer = artlib.ensureLayer(spr, "L")
    local cel = layer:cel(1) or spr:newCel(layer, 1, Image(8,8,spr.colorMode), Point(0,0))
    return artlib.stampGrid(cel.image, rows, palette, 0, 0)
  end)
  if ok then
    print(string.format("%-34s painted=%d skipped=%d w=%s h=%s colors=%s",
      label, res.painted, res.skippedOutOfBounds, tostring(res.width), tostring(res.height), tostring(res.distinctColors)))
  else
    print(string.format("%-34s ERROR: %s", label, tostring(res)))
  end
end

-- 1) 纯 ASCII：应该正常
try("ASCII X/o", { "XX..", ".XX.", "..XX" }, { ["."] = "", X = "#FF0000", o = "#00FF00" })

-- 2) 用方块字符当"像素"（模型很可能这么干）：怀疑全灭
try("方块字符 █/▒", { "██..", ".██.", "..██" }, { ["."] = "", ["█"] = "#FF0000", ["▒"] = "#00FF00" })

-- 3) 全角字符
try("全角 口/田", { "口口..", ".口口." }, { ["."] = "", ["口"] = "#FF0000", ["田"] = "#00FF00" })

-- 4) palette 把 "." 映射成颜色（应被视为透明）
try("库把 . 映射成颜色", { "XXXX", "XXXX" }, { ["."] = "#000000", X = "#FF0000" })

local px = 0
for y = 0, 7 do for x = 0, 7 do
  if app.activeSprite.layers[1]:cel(1).image:getPixel(x, y) ~= 0 then px = px + 1 end
end end
print("整张图非空像素 = " .. px)
