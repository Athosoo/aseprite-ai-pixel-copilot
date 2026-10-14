-- lib/menu.lua -- 命令表的"数据 + 文字排版"
--
-- 命令表现在是【终端里打印出来的文字】：
--   1) 用户敲 菜单 / menu -> 面板把表格逐行打印进滚回缓冲
--   2) 每一行带 meta.menuIndex，面板绘制时记录命中框 -> 悬浮变蓝、点击执行
--   3) 执行完自动重打一份（旧的往上滚）
--
-- 这里只负责"行数据"和"排版成文字"（纯字符串运算，无头可测）。
-- 列对齐用字符列宽估算：ASCII 算 1 列、CJK/全角算 2 列 —— 像素字体下够准，
-- 而且不需要 graphics context（打印时就能对齐）。

local menu = {}

-- 字符显示宽度（列）：ASCII 1 列，其余 2 列
local function columns(s)
  local n = 0
  for _, code in utf8.codes(s) do
    n = n + (code < 0x80 and 1 or 2)
  end
  return n
end
menu.columns = columns

local function padRight(s, want)
  local have = columns(s)
  if have >= want then return s end
  return s .. string.rep(" ", want - have)
end
menu.padRight = padRight

-- rows: { {id, keys, label, note}, ... }
-- 返回：逐行 { index=, id=, text= }
function menu.tableLines(rows)
  local out = {}
  if not rows or #rows == 0 then return out end

  -- label 列对齐到固定列宽（编号:键位 那列本来就是固定宽度）
  local labelCols = 0
  for _, r in ipairs(rows) do
    local c = columns(tostring(r.label or ""))
    if c > labelCols then labelCols = c end
  end
  if labelCols > 34 then labelCols = 34 end     -- 太长的 label 不撑爆表格

  for i, r in ipairs(rows) do
    local key = tostring(r.keys or "")
    local head = string.format(" %d:%s  ", i, key)
    local label = tostring(r.label or r.id or "")
    local note = tostring(r.note or "")
    local line = head .. padRight(label, labelCols)
    if note ~= "" then line = line .. "   " .. note end
    out[#out + 1] = { index = i, id = r.id, text = line }
  end
  return out
end

-- 表头（打印在表格上方的一行提示）
function menu.titleLine(i18n)
  return i18n.t("menuTitle") .. "   --   " .. i18n.t("menuFooter")
end

-- 菜单开着时，把一行输入解释成"选第几项"：
--   纯数字 -> 直接是序号；单个键位字母 -> 找 keys 匹配的那行
-- 返回 index 或 nil
function menu.resolveInput(rows, text)
  local s = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" or not rows then return nil end

  local num = s:match("^(%d+)$")
  if num then
    local i = tonumber(num)
    if i and i >= 1 and i <= #rows then return i end
    return nil
  end

  if #s == 1 and s:find("^[%a]$") then
    local want = s:lower()
    for i, r in ipairs(rows) do
      local k = tostring(r.keys or ""):lower()
      if k ~= "" and k == want then return i end
    end
  end
  return nil
end

return menu
