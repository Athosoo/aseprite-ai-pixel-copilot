local c = app.theme.color
local function rgb(name)
  local ok, col = pcall(function() return c[name] end)
  if not ok or not col then return "ERR" end
  local o1, r = pcall(function() return col.red end)
  local o2, g = pcall(function() return col.green end)
  local o3, b = pcall(function() return col.blue end)
  if not (o1 and o2 and o3) then return "ERR" end
  return string.format("%3d,%3d,%3d", r, g, b)
end
print("== 真名字 vs 假名字：值一样就说明是兜底，读不到真主题色 ==")
for _, n in ipairs({"window_face","window_text","window_border","background","text",
                    "button_face","selected","disabled","editor_face",
                    "this_is_not_a_color_name","zzzz",""}) do
  print(string.format("  %-28s = %s", "[" .. n .. "]", rgb(n)))
end
