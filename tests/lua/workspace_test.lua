-- tests/lua/workspace_test.lua -- 工作区流程：备份 / 副本 / 打开 / 交付（P10）
--
-- 跑法： 在仓库根执行
--   ASE_PROJ="$PWD" "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/workspace_test.lua
--
-- 这是改动最大、也最容易毁用户文件的一项，所以全程在**临时目录**里用真文件跑：
--   建一个真 .ase -> 打开它 -> 喂一条 run_ops 协议消息 -> 断言
--   备份存在、副本存在、app.activeSprite 指向副本。
-- 然后喂第二条 op，断言没有二次备份（已经建立了 managed 状态）。
-- 最后四个交付分支各断言一次行为。
--
-- 用到的文件 API 都是实测过的（tests/lua/ws_api_probe.lua）：
-- saveCopyAs / saveAs / Sprite:close / app.command.OpenFile{ui=false} / os.remove /
-- app.fs.makeAllDirectories。注意 Aseprite 读回来的 filename 是反斜杠。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local agent = require("lib.agent")
local workspace = require("lib.workspace")
local i18n = require("lib.i18n")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end

-- 临时工作目录（别碰用户任何真文件）
local TMP = os.getenv("TEMP") or os.getenv("TMP") or "."
TMP = TMP:gsub("\\", "/")
local BASE = TMP .. "/ai-pixel-copilot-ws-test"
local SRC = BASE .. "/gift"           -- 模拟用户的"gift"文件夹
local WSROOT = BASE .. "/workspace"   -- 模拟工作区

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function norm(p) return tostring(p or ""):gsub("\\", "/"):lower() end
local function leaf(p) return tostring(p or ""):gsub("\\", "/"):match("([^/]+)$") or "" end

-- 清空 + 重建
pcall(function() app.fs.makeAllDirectories(SRC) end)
pcall(function() app.fs.makeAllDirectories(WSROOT) end)

print("== 准备：造一张真 .ase 并打开它 ==")
local ORIG = SRC .. "/001.ase"
do
  local spr = Sprite(16, 16, ColorMode.RGB)
  app.activeSprite = spr
  app.activeCel.image:clear(Rectangle(0, 0, 16, 16), Color(255, 0, 0))
  spr:saveAs(ORIG)
  ok(exists(ORIG), "测试用的原文件建好了：" .. leaf(ORIG))
end

local a = agent.new{ port = 1 }
local sent, logs = {}, {}
a.send = function(_, msg) sent[#sent + 1] = msg end
a.panel = {
  log = function(_, text, kind) logs[#logs + 1] = { text = text, kind = kind } end,
  setStatus = function() end,
  setAsk = function() end,
  _showAskDialog = function() end,
  _closeAskDialog = function() end,
  showDeliverDialog = function(_, labels, onPick) a._deliverPicker = onPick end,
}
a.workspace:setRoot(WSROOT)

local function feed(msg)
  sent, logs = {}, {}
  a:onMessage(msg)
  return sent[1]
end

local function wsFiles()
  -- 收集工作区里 uploads/backups 下的文件（用 os 的文件检查，避免依赖目录遍历）
  return exists(WSROOT .. "/backups/gift_back/001-" .. "x")
end

----------------------------------------------------------------------
print("== 工作区关闭时：一切照旧（不能因为我们加了功能就改变默认行为）==")
do
  a.workspace:setRoot("")
  local spr = Sprite{ fromFile = ORIG }
  app.activeSprite = spr
  local r = feed{ type = "run_ops", id = 1, label = "测试", ops = { { op = "replace_color", from = "#FF0000", to = "#00FF00" } } }
  ok(r.type == "ops_result" and r.ok == true, "照常执行算子")
  ok(norm(app.activeSprite.filename) == norm(ORIG), "还是原来的文档（没造副本）")
  a.workspace:setRoot(WSROOT)
end

print("== prepare：备份 + 副本 + 打开副本 ==")
do
  local spr = Sprite{ fromFile = ORIG }
  app.activeSprite = spr
  local docsBefore = #app.sprites

  local rep = a.workspace:prepare(app.activeSprite)
  ok(rep.ok == true, "prepare 成功", rep.error)
  ok(workspace.fileExists(rep.backup or ""), "备份校验通过（fileExists 认得它）")
  ok(rep.backup ~= nil and exists(rep.backup), "备份文件真的落盘了：" .. leaf(rep.backup or ""))
  ok(rep.copy ~= nil and exists(rep.copy), "副本文件真的落盘了：" .. leaf(rep.copy or ""))
  ok(norm(app.activeSprite.filename) == norm(rep.copy or "?"),
    "activeSprite 现在是副本，实际 " .. tostring(app.activeSprite.filename))
  ok(#app.sprites == docsBefore + 1,
    string.format("副本是**新开的一个标签页**（%d -> %d）", docsBefore, #app.sprites))
  ok(rep.backup:find("/backups/gift_back/") ~= nil,
    "备份落在 backups/gift_back/ 下（用了原文件夹名），实际 " .. tostring(rep.backup))
  ok(norm(workspace.parent(rep.copy)) == norm(SRC), "副本和原文件同目录（gift/）")
  ok(leaf(rep.copy):find("_001_copy%.ase$") ~= nil, "副本名符合 <时间戳>_001_copy.ase，实际 " .. leaf(rep.copy))
  ok(a.workspace:isCopy(app.activeSprite), "isCopy 认得出来")
  ok(#logs >= 1 and logs[#logs].text:find(i18n.t("wsBackup"), 1, true) ~= nil
     or logs[#logs].text:find("副本", 1, true) ~= nil
     or logs[#logs].text:find("copy", 1, true) ~= nil,
    "面板说明了备份和副本，实际 " .. tostring(logs[#logs] and logs[#logs].text))

  -- 第二次 prepare：已经是副本了，不该再造一份
  local rep2 = a.workspace:prepare(app.activeSprite)
  ok(rep2.skipped == true, "已经在编辑副本时不重复 prepare")
  ok(a.workspace:managedInfo().copy == rep.copy, "managed 没被换掉")
end

print("== 改画布：落在副本上，原文件不动 ==")
do
  local before = io.open(ORIG, "rb")
  local beforeSize = before and before:seek("end") or 0
  if before then before:close() end

  local r = feed{ type = "run_ops", id = 2, label = "换绿",
                  ops = { { op = "replace_color", from = "#FF0000", to = "#00FF00" } } }
  ok(r.type == "ops_result" and r.ok == true, "算子执行成功")
  ok(a.workspace:isCopy(app.activeSprite), "改的还是副本")

  local px = app.activeCel.image:getPixel(0, 0)
  -- 0xAABBGGRR 打包：绿 = 0x00FF00，蓝 = 0xFF0000
  ok((px & 0x00FFFFFF) == 0x00FF00, "副本真的被改了（绿），实际 " ..
    string.format("%06X", px & 0x00FFFFFF))

  local after = io.open(ORIG, "rb")
  local afterSize = after and after:seek("end") or 0
  if after then after:close() end
  ok(afterSize == beforeSize and beforeSize > 0, "原文件大小没变（没被这次编辑碰到）")
end

print("== 交付 1/4：继续修改 ==")
do
  a:deliver()
  ok(a._deliverPicker ~= nil, "交付对话框弹出来了（onPick 被注册）")
  a._deliverPicker(4)                       -- 4 = 继续修改
  ok(a.workspace:hasPending() == true, "继续修改 -> managed 保留")
  ok(a.workspace:isCopy(app.activeSprite), "还在副本上")
end

print("== 交付 2/4：保留副本（不覆盖原文件）==")
do
  local copyPath = a.workspace:managedInfo().copy
  a:deliver()
  a._deliverPicker(2)                       -- 2 = 保留副本
  ok(a.workspace:hasPending() == false, "managed 清掉了")
  ok(exists(copyPath), "副本文件留在磁盘上")
  ok(#logs >= 1, "面板报告了结果")
end

print("== 交付 3/4：丢弃副本（删副本，备份留着）==")
do
  -- 重新 prepare 一次，造出新的副本
  app.activeSprite = Sprite{ fromFile = ORIG }
  local rep = a.workspace:prepare(app.activeSprite)
  ok(rep.ok == true, "重新 prepare 成功")
  local copyPath, bakPath = rep.copy, rep.backup
  local docsBefore = #app.sprites

  a:deliver()
  a._deliverPicker(3)                       -- 3 = 丢弃副本
  ok(exists(copyPath) == false, "副本文件被删了")
  ok(exists(bakPath) == true, "备份**留着**（那是安全网）")
  ok(#app.sprites < docsBefore, "副本的标签页也关掉了")
  ok(a.workspace:hasPending() == false, "managed 清掉了")
end

print("== 交付 4/4：覆盖原文件 ==")
do
  app.activeSprite = Sprite{ fromFile = ORIG }
  local rep = a.workspace:prepare(app.activeSprite)
  ok(rep.ok == true, "重新 prepare 成功")

  -- 在副本上画成蓝色
  app.transaction("test", function()
    app.activeCel.image:clear(Rectangle(0, 0, 16, 16), Color(0, 0, 255))
  end)
  local copyPath = rep.copy

  a:deliver()
  a._deliverPicker(1)                       -- 1 = 覆盖原文件
  ok(a.workspace:hasPending() == false, "managed 清掉了")
  ok(norm(app.activeSprite.filename) == norm(ORIG), "当前标签现在指向原文件")

  -- 原文件真的被覆盖了：重新读一遍看颜色
  local reread = Sprite{ fromFile = ORIG }
  local px = reread.cels[1].image:getPixel(0, 0)
  -- 注意 getPixel 的打包是 0xAABBGGRR（R 在最低字节）：实测 Color(255,0,0) 读回来是 0x0000FF。
  -- 所以"蓝"在这里是 0xFF0000。
  ok((px & 0x00FFFFFF) == 0xFF0000,
    "原文件内容已更新为蓝色，实际 " .. string.format("%06X", px & 0x00FFFFFF))
  ok(exists(copyPath), "副本文件还在（覆盖不会删副本）")
end

print("== 安全线：没保存过的新文档要拒绝，而不是瞎猜路径 ==")
do
  local fresh = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = fresh
  local rep = a.workspace:prepare(app.activeSprite)
  ok(rep.ok == false, "未保存的新文档被拒")
  ok(rep.reason == "untitled", "原因是 untitled，实际 " .. tostring(rep.reason))
  ok(type(rep.error) == "string" and rep.error ~= "", "给了用户看得懂的说明")
end

print("== prepare 失败 -> 编辑被中止（不许'备份失败照样改'）==")
do
  app.activeSprite = Sprite{ fromFile = ORIG }
  -- 把 root 指到一个不可能建目录的地方，逼 prepare 失败
  a.workspace:setRoot("Z:/definitely/not/here")
  sent, logs = {}, {}
  local blocked = a:prepareEdit("run_ops")
  ok(blocked == false, "prepareEdit 返回 false = 中止")
  ok(#sent == 1 and sent[1].type == "edit_blocked", "把中止原因推给了桥，实际 " ..
    tostring(sent[1] and sent[1].type))
  ok(#logs >= 1 and logs[#logs].kind == "error", "面板报了错")
  a.workspace:setRoot(WSROOT)
end

print("== P11 打开文档：路径解析 + 后缀白名单 ==")
do
  -- 相对路径按工作区根解析
  local p = a.workspace:resolve("gift/001.ase")
  ok(p == WSROOT .. "/gift/001.ase", "相对路径拼到工作区根上，实际 " .. tostring(p))

  -- 绝对路径原样
  ok(a.workspace:resolve("D:/x/y.png") == "D:/x/y.png", "绝对路径原样返回")

  -- 后缀白名单
  ok(a.workspace:isOpenable("a/b/001.ase") == true, ".ase 允许")
  ok(a.workspace:isOpenable("a/b/x.PNG") == true, "大写 .PNG 也允许")
  ok(a.workspace:isOpenable("a/b/secrets.txt") == false, ".txt 拒绝")
  ok(a.workspace:isOpenable("a/b/noext") == false, "没后缀拒绝")
  ok(a.workspace:isOpenable("a/b/run.lua") == false, ".lua 拒绝（不能被诱导去执行脚本）")

  -- 真打开一个文件
  sent, logs = {}, {}
  a:onMessage{ type = "open_doc", id = 42, path = "gift/001.ase" }
  -- 注意：工作区根下没有 gift/，所以这里应该失败并报错（而不是静默）
  ok(#sent == 1 and sent[1].type == "open_doc_result", "回了 open_doc_result")
  ok(sent[1].ok == false, "不存在的路径 -> 明确报错，不开空文档")

  -- 用真路径打开
  sent, logs = {}, {}
  a:onMessage{ type = "open_doc", id = 43, path = ORIG }
  ok(#sent == 1 and sent[1].ok == true, "真文件能打开", sent[1] and sent[1].error)
  ok(sent[1].width == 16 and sent[1].height == 16, "报回尺寸 16x16")
  ok(norm(app.activeSprite.filename) == norm(ORIG), "activeSprite 是它")
end

print("== P13 上传落地：复制进工作区，原图不动 ==")
do
  local srcImg = SRC .. "/upload_src.png"
  -- 造一张 png 当"用户的图"
  local s2 = Sprite(8, 8, ColorMode.RGB)
  s2.cels[1].image:clear(Rectangle(0, 0, 8, 8), Color(10, 20, 30))
  s2:saveCopyAs(srcImg)
  ok(exists(srcImg), "造了一张源图")

  local copied, err = a.workspace:copyIn(srcImg)
  ok(copied ~= nil and exists(copied), "复制件存在，err=" .. tostring(err))
  ok(copied ~= srcImg, "复制件是新文件，不是原路径")
  ok(norm(workspace.parent(copied)) == norm(WSROOT .. "/uploads"),
    "落在 <root>/uploads/ 下，实际 " .. tostring(copied))
  ok(exists(srcImg), "原图还在（一个字节都没动）")

  -- 已经在工作区里了：不重复复制
  local again = a.workspace:copyIn(copied)
  ok(again == copied, "工作区里的文件不再复制一份")

  -- 工作区关闭时原样返回
  a.workspace:setRoot("")
  local passthrough = a.workspace:copyIn(srcImg)
  ok(passthrough == srcImg, "工作区关闭 -> 直接用原路径")
  a.workspace:setRoot(WSROOT)
end

print("== 上传走 agent：工作区开启时读的是复制件 ==")
do
  local srcImg = SRC .. "/upload2.png"
  local s3 = Sprite(4, 4, ColorMode.RGB)
  s3.cels[1].image:clear(Rectangle(0, 0, 4, 4), Color(1, 2, 3))
  s3:saveCopyAs(srcImg)

  local binaryHeader
  a.conn = {
    isOpen = function() return true end,
    sendBinary = function(_, header) binaryHeader = header end,
    send = function() end,
  }
  sent, logs = {}, {}
  a:upload(srcImg)
  ok(binaryHeader ~= nil, "发出了上传帧")
  a.conn = nil
end

print("== 工作区文件列表（list_workspace，P13）==")
do
  local files = a.workspace:listFiles()
  ok(type(files) == "table", "返回表")
  ok(#files > 0, "列到了东西（uploads/backups 里我们写过文件），实际 " .. #files)

  local hasUpload, hasBackup = false, false
  for _, f in ipairs(files) do
    if f.dir == "uploads" then hasUpload = true end
    -- 备份在 backups/<原文件夹名>_back/ 下，所以是按前缀判断
    if f.dir:find("^backups") then hasBackup = true end
    ok(f.name ~= nil and f.path ~= nil, "每一项都有 name/path")
    ok(type(f.size) == "number" and f.size > 0,
      "每一项带文件大小（G7），" .. tostring(f.name) .. " -> " .. tostring(f.size))
  end
  ok(hasUpload, "列出了 uploads 里的复制件")
  ok(hasBackup, "列出了 backups 里的备份")

  -- 协议通道
  sent, logs = {}, {}
  a:onMessage{ type = "list_workspace", id = 55 }
  ok(#sent == 1 and sent[1].type == "workspace_result", "回了 workspace_result")
  ok(sent[1].root == workspace.toSlash(WSROOT):gsub("/+$", ""), "带上了工作区根，实际 " .. tostring(sent[1].root))
  ok(#sent[1].files > 0, "列表非空")

  -- 工作区关掉时列表为空（诚实：没有工作区就没有可列的东西）
  a.workspace:setRoot("")
  ok(#a.workspace:listFiles() == 0, "工作区关闭 -> 空列表")
  a.workspace:setRoot(WSROOT)
end

print("== 状态栏标出 [副本] ==")
do
  app.activeSprite = Sprite{ fromFile = ORIG }
  local rep = a.workspace:prepare(app.activeSprite)
  ok(rep.ok == true, "prepare 成功")
  local name = a:docName()
  ok(name:find(i18n.t("wsCopyTag"), 1, true) ~= nil, "文档名带了副本标记，实际 " .. name)
  a.workspace:setRoot("")
  app.activeSprite = Sprite{ fromFile = ORIG }
  ok(a:docName():find(i18n.t("wsCopyTag"), 1, true) == nil, "工作区关闭时不标")
end

print(string.format("%d passed, %d failed", pass, fail))
