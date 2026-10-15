-- tests/lua/ws_api_probe.lua -- 工作区流程用到的文件 API 探针（P10）
--
-- 要确认的（都没写在官方文档里，只能实测）：
--   * app.fs.makeAllDirectories / filePath / fileTitle
--   * sprite:saveCopyAs（备份和副本都靠它，**不能**用 saveAs 做备份）
--   * app.command.OpenFile{ filename = ..., ui = false }（打开副本）
--   * sprite:saveAs(原路径)（"覆盖原文件"）
--   * os.remove（"丢弃副本"）
--
-- 跑法：
--   ASE_WS_DIR=<一个空临时目录> ASE_PROBE_OUT=<输出文件> \
--     aseprite -b --script tests/lua/ws_api_probe.lua
-- 不设 ASE_WS_DIR 时用系统临时目录下的 ai-pixel-copilot-wsprobe。

local DIR = os.getenv("ASE_WS_DIR")
if not DIR or DIR == "" then
  DIR = os.getenv("TEMP") and (os.getenv("TEMP") .. "/ai-pixel-copilot-wsprobe")
        or "/tmp/ai-pixel-copilot-wsprobe"
end
DIR = DIR:gsub("\\", "/")

local OUT = os.getenv("ASE_PROBE_OUT")
local function say(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  print(line)
  if OUT and OUT ~= "" then
    local f = io.open(OUT, "a")
    if f then f:write(line .. "\n"); f:close() end
  end
end

say("== app.fs 能力 ==")
say("makeAllDirectories type = " .. type(app.fs.makeAllDirectories))
say("filePath = " .. type(app.fs.filePath) .. "  fileTitle = " .. type(app.fs.fileTitle))
pcall(function() say("filePath(D:/a/b/c.ase) = " .. tostring(app.fs.filePath("D:/a/b/c.ase"))) end)
pcall(function() say("fileTitle(D:/a/b/c.ase) = " .. tostring(app.fs.fileTitle("D:/a/b/c.ase"))) end)
pcall(function() say("currentPath = " .. tostring(app.fs.currentPath)) end)

local spr = Sprite(8, 8, ColorMode.RGB)
say("== Sprite 方法 ==")
say("saveCopyAs = " .. type(spr.saveCopyAs) .. "  saveAs = " .. type(spr.saveAs))

spr:newLayer()
spr.layers[1].name = "L1"
app.activeSprite = spr
spr.cels[1].image:clear(Rectangle(0, 0, 8, 8), Color(255, 0, 0))

say("== 建目录（备份目录是嵌套的）==")
local ok, err = pcall(function() app.fs.makeAllDirectories(DIR .. "/backups/gift_back") end)
say("makeAllDirectories ok=" .. tostring(ok) .. " err=" .. tostring(err))

say("== 保存原文件 ==")
local orig = DIR .. "/001.ase"
ok, err = pcall(function() spr:saveAs(orig) end)
say("saveAs ok=" .. tostring(ok) .. " err=" .. tostring(err))
say("filename = " .. tostring(app.activeSprite.filename))

say("== saveCopyAs 备份（不动当前文档）==")
local bak = DIR .. "/backups/gift_back/001-20261015-120000.ase"
ok, err = pcall(function() spr:saveCopyAs(bak) end)
say("saveCopyAs ok=" .. tostring(ok) .. " err=" .. tostring(err))
local f = io.open(bak, "rb")
say("备份存在 = " .. tostring(f ~= nil))
if f then f:close() end
say("备份后当前 filename 仍是原文件 = " .. tostring(app.activeSprite.filename == orig))

say("== saveCopyAs 副本 ==")
local copy = DIR .. "/20261015-120000_001_copy.ase"
ok, err = pcall(function() spr:saveCopyAs(copy) end)
say("copy ok=" .. tostring(ok) .. " err=" .. tostring(err))
f = io.open(copy, "rb"); say("副本存在 = " .. tostring(f ~= nil)); if f then f:close() end

say("== OpenFile{filename=, ui=false} 打开副本 ==")
local before = app.activeSprite and app.activeSprite.filename or ""
ok, err = pcall(function() app.command.OpenFile{ filename = copy, ui = false } end)
say("OpenFile ok=" .. tostring(ok) .. " err=" .. tostring(err))
say("before  = " .. before)
say("after   = " .. tostring(app.activeSprite and app.activeSprite.filename))
say("打开了副本 = " .. tostring((app.activeSprite and app.activeSprite.filename) == copy))
say("文档数 = " .. tostring(#app.sprites))

say("== 覆盖原文件（副本 saveAs 回原路径）==")
ok, err = pcall(function() app.activeSprite:saveAs(orig) end)
say("saveAs 回原路径 ok=" .. tostring(ok) .. " err=" .. tostring(err))
say("现在 filename = " .. tostring(app.activeSprite.filename))

say("== os.remove（丢弃副本）==")
ok, err = pcall(function() os.remove(copy) end)
say("os.remove ok=" .. tostring(ok) .. " err=" .. tostring(err))
f = io.open(copy, "rb"); say("副本已删 = " .. tostring(f == nil)); if f then f:close() end

say("== 路径分隔符：Aseprite 返回反斜杠 ==")
local mixed = DIR .. "/sep_test.ase"
ok, err = pcall(function() app.activeSprite:saveAs(mixed) end)
say("saveAs ok=" .. tostring(ok))
local got = tostring(app.activeSprite.filename)
say("存进去的是 " .. mixed)
say("读出来的是 " .. got)
say("直接比较相等 = " .. tostring(got == mixed) .. "   （所以必须归一化后再比！）")
say("反斜杠转正斜杠后相等 = " ..
  tostring(got:gsub("\\", "/") == mixed))

say("== Sprite:close（丢弃副本时关标签页）==")
say("Sprite.close 类型 = " .. type(app.activeSprite.close))
say("关之前文档数 = " .. tostring(#app.sprites))
ok, err = pcall(function() app.activeSprite:close() end)
say("close ok=" .. tostring(ok) .. " err=" .. tostring(err))
say("关之后文档数 = " .. tostring(#app.sprites))

pcall(function() os.remove(mixed) end)

say("PROBE EXIT")
