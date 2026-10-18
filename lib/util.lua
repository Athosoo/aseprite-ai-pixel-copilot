-- lib/util.lua -- 共用小工具（颜色、区域、字符串）
local util = {}

function util.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

function util.round(v)
  return math.floor(v + 0.5)
end

-- "#RGB" / "#RRGGBB" / "#RRGGBBAA" -> r, g, b, a(可选)
function util.hexToRgb(hex)
  if type(hex) ~= "string" then return nil end
  local s = hex:gsub("^#", "")
  if #s == 3 then
    s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2)
  end
  if #s ~= 6 and #s ~= 8 then return nil end
  local r = tonumber(s:sub(1, 2), 16)
  local g = tonumber(s:sub(3, 4), 16)
  local b = tonumber(s:sub(5, 6), 16)
  local a = (#s == 8) and tonumber(s:sub(7, 8), 16) or 255
  if not r or not g or not b then return nil end
  return r, g, b, a
end

function util.rgbToHex(r, g, b)
  return string.format("#%02X%02X%02X", util.round(r), util.round(g), util.round(b))
end

-- 把区域裁剪到画布内；region 可为 nil（= 整图）
function util.normRegion(region, w, h)
  region = region or {}
  local x = math.floor(tonumber(region.x) or 0)
  local y = math.floor(tonumber(region.y) or 0)
  local rw = math.floor(tonumber(region.w) or (w - x))
  local rh = math.floor(tonumber(region.h) or (h - y))
  x = util.clamp(x, 0, w)
  y = util.clamp(y, 0, h)
  rw = util.clamp(rw, 0, w - x)
  rh = util.clamp(rh, 0, h - y)
  return { x = x, y = y, w = rw, h = rh }
end

function util.regionIsFull(region, w, h)
  return region.x == 0 and region.y == 0 and region.w == w and region.h == h
end

function util.regionToString(region)
  if not region then return "整图" end
  return string.format("(%d,%d) %dx%d", region.x, region.y, region.w, region.h)
end

-- Lua 模式串里的特殊字符转义（用于 string.gsub 的 plain 匹配）
function util.escapePattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- gsub 替换串里的 % 转义
function util.escapeReplacement(s)
  return (s:gsub("%%", "%%%%"))
end

-- 按行切分；【保留空行】（多段回复里的空行是有意义的可读性）
function util.splitLines(text)
  local out = {}
  local t = tostring(text) .. "\n"
  for line in t:gmatch("([^\r\n]*)[\r\n]") do
    out[#out + 1] = line
  end
  if #out == 0 then out[1] = "" end
  return out
end

return util
