-- 探针：Aseprite 到底允不允许脚本往【它自己的状态栏 / 主窗口】加按钮？
--
--   ASE_PROBE_OUT=out.txt aseprite -b --script tests/lua/_statusbar_api_probe.lua

local out = {}
local function p(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  out[#out + 1] = table.concat(t, " ")
end

-- 1) app 里有没有跟状态栏 / 界面挂件相关的成员
local names = {}
for k in pairs(app) do names[#names + 1] = tostring(k) end
table.sort(names)
p("A1 app 的成员:", table.concat(names, " "))

-- 2) 名字里带 bar / status / ui / widget / dock 的都列出来（含是否 nil）
for _, k in ipairs({ "statusBar", "status_bar", "ui", "mainWindow", "window", "dock",
                     "workspace", "preferences", "commands", "command", "theme", "menus" }) do
  local ok, v = pcall(function() return app[k] end)
  local t = type(v)
  if t == "table" then
    local sub = {}
    for kk in pairs(v) do sub[#sub + 1] = tostring(kk) end
    table.sort(sub)
    if #sub > 40 then sub = { table.concat(sub, " ", 1, 40), "…(" .. #sub .. ")" } end
    p("A2 app." .. k .. " = table ->", table.concat(sub, " "))
  else
    p("A2 app." .. k .. " =", t, tostring(v))
  end
end

-- 3) app.ui 是唯一可能挂界面的地方，逐字段看
if type(app.ui) == "table" then
  for k, v in pairs(app.ui) do
    p("A3 app.ui." .. tostring(k) .. " =", type(v), tostring(v))
  end
end

-- 4) Dialog/Canvas 之外，有没有"能被 Aseprite 主窗口托管"的控件？
local okW, ww2 = pcall(function() return app.window.width end)
p("A4 app.window 存在（-b 下通常没有）:", okW, tostring(ww2))

-- 5) 命令系统：脚本能不能注册一条命令并让它出现在菜单/状态栏
p("A6 app.command 存在:", type(app.command))
local okC, cv = pcall(function() return app.command.StatusBar end)
p("A7 app.command 里有 StatusBar 之类吗:", okC, tostring(cv))

local f = io.open(os.getenv("ASE_PROBE_OUT") or "/tmp/_statusbar_api_probe.out", "w")
f:write(table.concat(out, "\n") .. "\n")
f:close()
