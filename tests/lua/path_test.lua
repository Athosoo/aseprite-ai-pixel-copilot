-- tests/lua/path_test.lua
--
-- 验证【安装后的路径机制】：扩展目录里的 __project.lua 能被读出来，
-- 而且它指向的 bridge 真的存在。
-- 改了 main.lua 的路径探测 / install.ps1 之后跑这个。
--
--   "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/path_test.lua
--
-- 前提：先跑过一次 install.ps1（它会写 __project.lua）。

local pass, fail = 0, 0
local function ok(cond, name)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name)
  end
end

print("== 安装路径机制（__project.lua -> bridge）==")

local base = app.fs.userConfigPath or ""
local projFile = base .. "/extensions/ai-pixel-copilot/__project.lua"

local f = io.open(projFile, "r")
ok(f ~= nil, "能打开 __project.lua")
if not f then
  print("  (文件不在：" .. projFile .. "；先跑一次 install.ps1)")
  print(string.format("%d passed, %d failed", pass, fail))
  return
end

local dir = (f:read("*a") or "")
f:close()
dir = dir:gsub("^%s+", ""):gsub("%s+$", "")

ok(dir ~= "", "项目根非空 -> 「" .. dir .. "」")
-- BOM 会让路径开头多出 \239\187\191，Lua 读出来就废了（install.ps1 特意用
-- WriteAllText 而不是 Set-Content 就是为了这个）
ok(dir:find("\239\187\191") == nil, "没有 UTF-8 BOM 残留")
ok(app.fs.isFile(dir .. "\\bridge\\src\\server.mjs"), "bridge/src/server.mjs 存在")
ok(app.fs.isFile(dir .. "\\bridge\\package.json"), "bridge/package.json 存在")

print(string.format("%d passed, %d failed", pass, fail))
