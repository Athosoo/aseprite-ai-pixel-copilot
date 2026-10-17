-- lib/theme.lua -- 设计令牌 + 从 sprite 调色板派生 accent（ui §3）
--
-- 为什么 accent 要派生：工作台的强调色取自**当前这张画**，工具于是永远和它编辑的图
-- 同一种气质，且随图而变。取不到（无调色板 / 全是黑白灰）就退回品牌蓝，
-- 此时行为与 v0.5.x 完全一致（D4）。
--
-- 派生逻辑是纯函数（theme.deriveAccent(颜色数组) -> hex），所以能无头断言。

local util = require("lib.util")
local i18n = require("lib.i18n")

local theme = {}

theme.DEFAULT_ACCENT = "#6ea8fe"      -- 品牌蓝：取不到调色板时的唯一兜底
theme.ACCENT_L = 0.62                 -- 派生色的明度：深底上要能读，又不像荧光笔
theme.ACCENT_S_MIN, theme.ACCENT_S_MAX = 0.42, 0.85
theme.MIN_VALUE = 26                  -- 比这更暗的颜色画到深色底上等于不可见
theme.MIN_CHROMA = 18                 -- 比这更接近灰的不算"有彩度"

----------------------------------------------------------------------
-- 令牌（ui §3.1 逐字）
----------------------------------------------------------------------

theme.TOKENS = {
  dark = {
    bg = "#111318", surface = "#171a20", surface2 = "#1d2129",
    line = "#2a2f39", lineHi = "#3a414e",
    text = "#dfe3ea", dim = "#79818f", faint = "#4d5461",
    ok = "#5ec98a", warn = "#e0b34a", err = "#e2657a", busy = "#7f9cf5",
  },
  -- 浅色同构：只换底色与文字，语义色微调亮度，accent 不换
  light = {
    bg = "#f4f5f7", surface = "#eceef2", surface2 = "#e2e5ea",
    line = "#cdd2da", lineHi = "#aab1bd",
    text = "#1e2229", dim = "#5b6270", faint = "#9aa1ad",
    ok = "#3d9e69", warn = "#b3861f", err = "#c1435a", busy = "#5b78d6",
  },
}

-- 栅格只有四档（ui §3.3）：4 / 8 / 12 / 16。像素值写死在这里，别的地方一律引用。
theme.SPACE = { 4, 8, 12, 16 }

theme.METRICS = {
  lineH = 14, rowH = 18,          -- 行高 14，行间距 4 -> 列表单行 18
  gap = 4, pad = 8, viewPad = 12, -- 内边距：视图 12 / 面板 8 / 按钮 4x8
  titleH = 30, railW = 56, ctxW = 240, composerH = 40,
  hair = 1, accentBar = 2,
  minW = 640, minH = 420, defaultW = 900, defaultH = 620,
  narrowCtx = 760,                -- 宽 < 760 右上下文自动折叠
}

-- 自绘图标的字形集（ui §4）。都用现成 Unicode，不引位图。
theme.ICONS = {
  console = "▤", canvas = "◎", styles = "◈", memory = "✦",
  packs = "⬡", gallery = "▦", settings = "⚙", new = "⊕",
  stop = "⏹", attach = "📎", rollback = "↺",
  left = "◂", right = "▸", dot = "·", check = "✓",
}

----------------------------------------------------------------------
-- 颜色工具
----------------------------------------------------------------------

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end
theme.clamp = clamp

-- Aseprite 的 Color userdata 对**不存在的字段会抛错**（不是返回 nil），
-- 所以探测字段必须包 pcall —— 否则一个 {r,g,b} 表格混进来就炸。
local function probe(o, k)
  local ok, v = pcall(function() return o[k] end)
  if ok then return v end
  return nil
end

-- 接受 Color 对象 / {r,g,b} / {red,green,blue} / 数组 / "#RRGGBB"
function theme.toRgb(c)
  if c == nil then return nil end
  if type(c) == "string" then
    local r, g, b = util.hexToRgb(c)
    if not r then return nil end
    return r, g, b
  end
  local r, g, b
  if type(c) == "table" then
    r, g, b = c.r or c.red, c.g or c.green, c.b or c.blue
    if r == nil then r, g, b = c[1], c[2], c[3] end
  else
    r, g, b = probe(c, "r") or probe(c, "red"), probe(c, "g") or probe(c, "green"), probe(c, "b") or probe(c, "blue")
  end
  if r == nil or g == nil or b == nil then return nil end
  return r, g, b
end

function theme.rgbToHsl(r, g, b)
  r, g, b = r / 255, g / 255, b / 255
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local l = (mx + mn) / 2
  local c = mx - mn
  if c == 0 then return 0, 0, l end
  local s
  if l > 0.5 then s = c / (2 - mx - mn) else s = c / (mx + mn) end
  local h
  if mx == r then h = ((g - b) / c) % 6
  elseif mx == g then h = (b - r) / c + 2
  else h = (r - g) / c + 4 end
  return h * 60, s, l
end

function theme.hslToRgb(h, s, l)
  h = h % 360
  local c = (1 - math.abs(2 * l - 1)) * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = l - c / 2
  local r, g, b
  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  return (r + m) * 255, (g + m) * 255, (b + m) * 255
end

----------------------------------------------------------------------
-- accent 派生
----------------------------------------------------------------------

-- 返回 hex, meta{index, sat, hex}
-- 判据按 ui §1 第 3 条的字面意思：**彩度最高**。彩度并列时取明度更接近可视基准的
-- （纯黑纯白不参与），再并列取靠前的 —— 保证同一张图每次得到同一个 accent。
function theme.deriveAccent(list)
  local best, bestIdx, bestSat = nil, nil, -1
  if type(list) ~= "table" then return theme.DEFAULT_ACCENT, nil end
  for i = 1, #list do
    local r, g, b = theme.toRgb(list[i])
    if r then
      local mx = math.max(r, g, b)
      local mn = math.min(r, g, b)
      local chroma = mx - mn
      if mx >= theme.MIN_VALUE and chroma >= theme.MIN_CHROMA then
        local sat = chroma / mx
        local better = false
        if sat > bestSat + 1e-9 then
          better = true
        elseif math.abs(sat - bestSat) <= 1e-9 then
          local v = mx / 255
          local curBestV = best and best.v or -1
          if math.abs(v - 0.62) < math.abs(curBestV - 0.62) then better = true end
        end
        if better then
          best = { r = r, g = g, b = b, sat = sat, v = mx / 255 }
          bestIdx = i
          bestSat = sat
        end
      end
    end
  end
  if not best then return theme.DEFAULT_ACCENT, nil end

  -- 只保色相：明度抬到深底上读得清的那一档，饱和度夹在中间区间，
  -- 否则"彩度最高"往往就是纯 #FF0000，直接当强调色会刺眼且和主题打架。
  local h, s = theme.rgbToHsl(best.r, best.g, best.b)
  s = clamp(s, theme.ACCENT_S_MIN, theme.ACCENT_S_MAX)
  local r, g, b = theme.hslToRgb(h, s, theme.ACCENT_L)
  local hex = util.rgbToHex(r, g, b)
  return hex, { index = bestIdx, sat = best.sat, hex = hex }
end

-- 调色板颜色表：接受 sprite（唯一入口，不碰 app.*）。取不到返回 nil。
function theme.paletteOf(sprite)
  if not sprite then return nil end
  local ok, pals = pcall(function() return sprite.palettes end)
  if not ok or not pals then return nil end
  local n = 0
  local okn, palN = pcall(function() return #pals end)
  if okn and palN then n = palN end
  if n == 0 then return nil end
  local pal = pals[1]
  if not pal then return nil end
  local okc, count = pcall(function() return #pal end)
  if not okc or not count or count == 0 then return nil end
  local out = {}
  for i = 0, count - 1 do
    local oki, col = pcall(function() return pal:getColor(i) end)
    if oki and col then out[#out + 1] = { col.red, col.green, col.blue } end
  end
  if #out == 0 then return nil end
  return out
end

function theme.accentForSprite(sprite)
  local list = theme.paletteOf(sprite)
  if not list then return theme.DEFAULT_ACCENT, nil end
  return theme.deriveAccent(list)
end

----------------------------------------------------------------------
-- 主题对象（Kit.new(gc, theme) 吃这个）
----------------------------------------------------------------------

function theme.new(opts)
  opts = opts or {}
  local name = opts.name or "dark"
  local tokens = theme.TOKENS[name] or theme.TOKENS.dark
  local th = {
    name = name,
    colors = {},
    metrics = {},
    space = theme.SPACE,
    icons = theme.ICONS,
    -- 语言交给 kit 用来挑文案：标签宽度进布局，所以这个决定只能有一个来源
    locale = opts.locale or (i18n.isZh() and "zh" or "en"),
  }
  for k, v in pairs(tokens) do
    local r, g, b = util.hexToRgb(v)
    th.colors[k] = Color(r or 0, g or 0, b or 0)
  end
  for k, v in pairs(theme.METRICS) do th.metrics[k] = v end

  local accentHex = opts.accent
  if not accentHex and opts.sprite then accentHex = theme.accentForSprite(opts.sprite) end
  th.accentHex = accentHex or theme.DEFAULT_ACCENT
  local r, g, b = util.hexToRgb(th.accentHex)
  if r then th.colors.accent = Color(r, g, b) else th.accentHex = theme.DEFAULT_ACCENT end

  function th:color(nm) return self.colors[nm] or self.colors.text end
  function th:tone(nm) return self.colors[nm] or self.colors.text end
  function th:setAccent(hex)
    local rr, gg, bb = util.hexToRgb(hex)
    if not rr then return end
    self.accentHex = hex
    self.colors.accent = Color(rr, gg, bb)
  end
  function th:scale(k)
    for key, v in pairs(self.metrics) do
      if type(v) == "number" and key ~= "hair" then self.metrics[key] = math.floor(v * k + 0.5) end
    end
  end
  return th
end

-- 缺字回落：中文标签量出来是 0（字体没这个字）就换英文那版（ui §3.2）。
function theme.pickText(kit, zh, en, style)
  if zh == nil then return en or "" end
  local w = kit:measure(zh, style)
  if w and w > 0 then return zh end
  return en or zh
end

return theme
