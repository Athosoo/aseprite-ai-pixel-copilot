-- lib/workspace.lua -- 工作文件夹：备份 / 副本编辑 / 打开副本 / 交付（P10）
--
-- 用户设了一个工作区根目录之后，任何**会改画布**的请求落到"非副本"文档上时，
-- 先做一次 prepare：
--     原文件 gift/001.ase
--       -> 备份到  <root>/backups/gift_back/001-20261015-120000.ase   （只增不覆盖）
--       -> 复制出  gift/20261015-120000_001_copy.ase                  （与原文件同目录）
--       -> 在 Aseprite 里**打开副本**，之后所有算子自然落在副本上
-- 这是整个设计的关键：打开副本之后 app.activeSprite 就是副本，op 代码一行都不用改。
--
-- 交付（用户敲「交付」）给四个选择：覆盖原文件 / 保留副本 / 丢弃副本 / 继续修改。
--
-- 所有文件操作都 pcall 包住，任何一步失败都**中止本次编辑并明确报错** ——
-- 绝不允许"备份失败照样改"。备份用 saveCopyAs（不影响当前文档），
-- 只有"覆盖原文件"这一处会写原路径，而且必须经过用户点选。
--
-- 实测过的 API（tests/lua/ws_api_probe.lua）：
--   app.fs.makeAllDirectories(嵌套目录) / app.fs.filePath / app.fs.fileTitle
--   sprite:saveCopyAs(path) / sprite:saveAs(path) / sprite:close() / os.remove
--   app.command.OpenFile{ filename = p, ui = false }
--   注意：sprite.filename 读出来是**反斜杠**，和拼出来的正斜杠路径直接比较永远不相等，
--   所以路径一律先归一化再比（见 norm）。

local i18n = require("lib.i18n")

local workspace = {}
local Workspace = {}
Workspace.__index = Workspace

----------------------------------------------------------------------
-- 路径工具（都在这一处，别在别处再写一套）
----------------------------------------------------------------------

local function toSlash(p)
  return (tostring(p or ""):gsub("\\", "/"))
end

-- 比较用的归一化键
local function norm(p)
  return toSlash(p):lower()
end

-- 最后一个路径段（文件名带扩展名）
local function leaf(p)
  return toSlash(p):match("([^/]+)$") or ""
end

-- 去扩展名的文件名："D:/a/b/001.ase" -> "001"
local function stem(p)
  local name = leaf(p)
  return (name:gsub("%.[^%.]*$", ""))
end

-- 父目录："D:/a/b/001.ase" -> "D:/a/b"（没有分隔符时返回 ""）
local function parent(p)
  local s = toSlash(p)
  return s:match("^(.*)/[^/]*$") or ""
end

-- 文件是否存在。优先 io（没有副作用）；io 被权限挡住时退回 Sprite{fromFile=}
-- 读一下再关掉 —— 注意那个读会**多出一个文档**，所以读完必须 close，
-- 否则标签栏里会留一个莫名其妙的备份（实测踩过）。
local function fileExists(path)
  local okIo, f = pcall(io.open, path, "rb")
  if okIo then
    if f then
      pcall(function() f:close() end)
      return true
    end
    return false
  end
  local ok2, res = pcall(function()
    local probe = Sprite{ fromFile = path }
    if not probe then return false end
    pcall(function() probe:close() end)
    return true
  end)
  return ok2 and res == true
end

workspace.fileExists = fileExists
workspace.toSlash = toSlash
workspace.norm = norm
workspace.leaf = leaf
workspace.stem = stem
workspace.parent = parent

----------------------------------------------------------------------

-- opts = { getRoot = function() return root end, log = function(text, kind) end }
function workspace.new(opts)
  return setmetatable({
    opts = opts or {},
    root = "",
    managed = nil,      -- { original=, copy=, backup= }
  }, Workspace)
end

function Workspace:getRoot()
  local r = self.root
  if self.opts.getRoot then
    local ok, v = pcall(self.opts.getRoot)
    if ok and type(v) == "string" and v ~= "" then r = v end
  end
  return toSlash(r):gsub("/+$", "")
end

function Workspace:setRoot(root)
  self.root = toSlash(root or ""):gsub("/+$", "")
end

function Workspace:enabled()
  return self:getRoot() ~= ""
end

function Workspace:log(text, kind)
  if self.opts.log then pcall(self.opts.log, text, kind or "info") end
end

-- 时间戳：备份和副本名都用它（只增不覆盖，比固定名安全）
function Workspace:timestamp()
  local ok, s = pcall(os.date, "%Y%m%d-%H%M%S")
  if ok and type(s) == "string" and s ~= "" then return s end
  return tostring(os.time())
end

function Workspace:managedInfo()
  return self.managed
end

function Workspace:clearManaged()
  self.managed = nil
end

-- 当前打开的文档是不是我们自己造出来的副本
function Workspace:isCopy(spr)
  if not self.managed then return false end
  local f = spr and spr.filename or ""
  if f == "" then return false end
  return norm(f) == norm(self.managed.copy)
end

-- 当前文档是"已交付过的原文件"（编辑直接落在原文件上，不需要再 prepare）
function Workspace:isOriginal(spr)
  if not self.managed then return false end
  local f = spr and spr.filename or ""
  if f == "" then return false end
  return norm(f) == norm(self.managed.original)
end

----------------------------------------------------------------------
-- 编辑前准备：备份 + 副本 + 打开副本
----------------------------------------------------------------------

-- 返回 { ok = true, copy, backup, original, skipped? }
--   或 { ok = false, error = "..." }（调用方必须**中止**这次编辑）
function Workspace:prepare(spr)
  if not self:enabled() then return { skipped = true, reason = "disabled" } end
  if not spr then return { ok = false, error = i18n.t("wsNoDoc") } end

  local origPath = tostring(spr.filename or "")
  -- 注意：从没保存过的新文档，Aseprite 的 spr.filename 不是空串，而是 "Sprite"
  -- 这样的默认标题（实测）。所以判据是"没有目录部分"，不是"空串"。
  if origPath == "" or parent(origPath) == "" then
    -- 交付时的"覆盖"需要原路径，所以先让用户保存
    return { ok = false, reason = "untitled", error = i18n.t("wsNeedSave") }
  end

  -- 已经在编辑副本：不重复 prepare（这是设计的关键 —— 后续所有 op 直接落副本）
  if self:isCopy(spr) then
    return { skipped = true, reason = "already-copy", copy = self.managed.copy }
  end

  local root = self:getRoot()
  local dir = parent(origPath)
  local stemName = stem(origPath)
  local dirName = leaf(dir)
  if dirName == "" then dirName = "root" end

  local ts = self:timestamp()
  local bakDir = root .. "/backups/" .. dirName .. "_back"
  local bak = bakDir .. "/" .. stemName .. "-" .. ts .. ".ase"
  local copy = dir .. "/" .. ts .. "_" .. stemName .. "_copy.ase"

  local function fail(what, err)
    return { ok = false, error = string.format(i18n.t("wsStepFailed"), what, tostring(err)) }
  end

  local ok, err = pcall(function() app.fs.makeAllDirectories(bakDir) end)
  if not ok then return fail(i18n.t("wsMakeDir"), err) end

  -- 备份：saveCopyAs 不影响当前文档，也绝不会碰原路径
  ok, err = pcall(function() spr:saveCopyAs(bak) end)
  if not ok then return fail(i18n.t("wsBackup"), err) end
  -- saveCopyAs 在路径不可写时**只打印错误、不抛异常**（实测：写 Z: 盘这种不存在的路径时
  -- 仍然 pcall 成功）——所以必须自己确认备份真的写出来了，否则就是
  -- "备份失败照样改"，那是这一项最不能接受的失败方式。
  if not fileExists(bak) then
    return fail(i18n.t("wsBackupVerify"), bak)
  end

  -- 副本：放在原文件同目录
  ok, err = pcall(function() spr:saveCopyAs(copy) end)
  if not ok then return fail(i18n.t("wsCopy"), err) end

  -- 打开副本：打开之后 app.activeSprite 就是副本
  ok, err = pcall(function() app.command.OpenFile{ filename = copy, ui = false } end)
  if not ok then return fail(i18n.t("wsOpen"), err) end

  local opened = app.activeSprite and tostring(app.activeSprite.filename or "") or ""
  if norm(opened) ~= norm(copy) then
    -- 打开了别的文档 = 状态不可信，宁可报告失败也别在错误的文档上改
    return { ok = false, error = string.format(i18n.t("wsOpenWrong"), tostring(opened)) }
  end

  self.managed = { original = origPath, copy = copy, backup = bak }
  local rep = { ok = true, original = origPath, copy = copy, backup = bak }
  self:log(string.format(i18n.t("wsPrepared"), leaf(bak), leaf(copy)), "tool")
  return rep
end

----------------------------------------------------------------------
-- 交付（四个选择）
----------------------------------------------------------------------

-- 返回交付可选项的 id 列表（顺序就是弹窗里按钮的顺序）
workspace.DELIVER_CHOICES = { "overwrite", "keep", "discard", "continue" }

function Workspace:deliverLabels()
  return {
    i18n.t("wsOverwrite"),
    i18n.t("wsKeep"),
    i18n.t("wsDiscard"),
    i18n.t("wsContinue"),
  }
end

function Workspace:hasPending()
  return self.managed ~= nil
end

-- choice: "overwrite" | "keep" | "discard" | "continue" | "cancel"
function Workspace:deliver(choice)
  local m = self.managed
  if not m then return { ok = false, error = i18n.t("wsNothingPending") } end
  if choice == "continue" or choice == "cancel" or choice == nil then
    return { ok = true, action = "continue" }
  end

  local spr = app.activeSprite
  if not spr then return { ok = false, error = i18n.t("wsNoDoc") } end

  if choice == "overwrite" then
    if not self:isCopy(spr) then
      return { ok = false, error = i18n.t("wsNotTheCopy") }
    end
    local ok, err = pcall(function() spr:saveAs(m.original) end)
    if not ok then
      return { ok = false, error = string.format(i18n.t("wsStepFailed"), i18n.t("wsOverwrite"), tostring(err)) }
    end
    self.managed = nil
    self:log(string.format(i18n.t("wsOverwritten"), leaf(m.original), leaf(m.backup)), "tool")
    return { ok = true, action = "overwrite", original = m.original, backup = m.backup }
  end

  if choice == "keep" then
    self.managed = nil
    self:log(string.format(i18n.t("wsKept"), leaf(m.copy), leaf(m.backup)), "tool")
    return { ok = true, action = "keep", copy = m.copy, backup = m.backup }
  end

  if choice == "discard" then
    -- 先把副本刷到磁盘再关标签页 —— 文档是干净的，关的时候不会弹"要保存吗"
    if self:isCopy(spr) then
      pcall(function() spr:saveCopyAs(m.copy) end)
      pcall(function() spr:close() end)
    end
    local ok = pcall(function() os.remove(m.copy) end)
    self.managed = nil
    self:log(string.format(i18n.t("wsDiscarded"), leaf(m.copy), leaf(m.backup)), "tool")
    return { ok = true, action = "discard", removed = ok, backup = m.backup }
  end

  return { ok = false, error = string.format(i18n.t("wsUnknownChoice"), tostring(choice)) }
end

----------------------------------------------------------------------
-- 上传落地（P13）：把用户选的图片复制进工作区，再读复制件
----------------------------------------------------------------------

-- 返回新路径；失败返回 nil, err
function Workspace:copyIn(path)
  if not self:enabled() then return path end
  path = tostring(path or "")
  if path == "" then return nil, i18n.t("wsNeedSave") end

  -- 已经在工作区里了：不用再复制一份
  if norm(path):sub(1, #norm(self:getRoot())) == norm(self:getRoot()) then
    return path
  end

  local dir = self:getRoot() .. "/uploads"
  local dest = dir .. "/" .. self:timestamp() .. "_" .. leaf(path)

  local ok, err = pcall(function() app.fs.makeAllDirectories(dir) end)
  if not ok then return nil, string.format(i18n.t("wsStepFailed"), i18n.t("wsMakeDir"), tostring(err)) end

  -- 用 Sprite 读进来再 saveCopyAs —— 不依赖 Lua 侧的文件写权限，
  -- 也不碰原文件（只读它一次）
  ok, err = pcall(function()
    local src = Sprite{ fromFile = path }
    if not src then error("cannot read " .. path) end
    src:saveCopyAs(dest)
  end)
  if not ok then return nil, string.format(i18n.t("wsStepFailed"), i18n.t("wsCopyIn"), tostring(err)) end

  return dest
end

----------------------------------------------------------------------
-- 工作区内容列表（P13 的 list_workspace + P11 的相对路径解析）
----------------------------------------------------------------------

-- 列目录用 app.fs.listFiles（实测可用，见 ws_api_probe 同期的探针输出：
-- 返回的是**名字**，不是路径 —— 要自己拼回去）。
-- 只报我们确实写过的目录：uploads / backups。
function Workspace:listFiles()
  local out = {}
  if not self:enabled() then return out end
  local root = self:getRoot()
  local dirs = { root .. "/uploads", root .. "/backups" }

  -- dir 显示名：相对 root 的路径（backups/gift_back 这种），比拆名字拼更不容易错
  local function relDir(full)
    local sp = toSlash(parent(full))
    local sr = toSlash(root)
    if sr ~= "" and sp:sub(1, #sr) == sr then
      local rest = sp:sub(#sr + 1):gsub("^/", "")
      if rest ~= "" then return rest end
    end
    return leaf(sp)
  end

  local function walk(dir, depth)
    if depth > 3 then return end
    local ok, names = pcall(app.fs.listFiles, dir)
    if not ok or type(names) ~= "table" then return end
    for _, n in ipairs(names) do
      local name = tostring(n)
      local full = dir .. "/" .. name
      local isDir = false
      pcall(function() isDir = app.fs.isDirectory(full) end)
      if isDir then
        walk(full, depth + 1)
      else
        local size = nil
        pcall(function() size = app.fs.fileSize(full) end)
        out[#out + 1] = { name = name, path = full, dir = relDir(full), size = size }
      end
    end
  end

  for _, d in ipairs(dirs) do walk(d, 1) end
  return out
end

-- 把相对路径解析成绝对路径：优先按工作区根，其次当前文档所在目录
function Workspace:resolve(path)
  path = tostring(path or "")
  if path == "" then return nil, i18n.t("wsNoPath") end
  path = toSlash(path)
  -- 已经是绝对路径（D:/... 或 /...）：原样用
  if path:match("^%a:/") or path:match("^/") then return path end

  local root = self:getRoot()
  if root ~= "" then return root .. "/" .. path end

  local spr = app.activeSprite
  local cur = spr and tostring(spr.filename or "") or ""
  local dir = parent(cur)
  if dir == "" then return nil, i18n.t("wsNoPath") end
  return dir .. "/" .. path
end

-- 只允许打开这些后缀（防止模型被诱导去"打开"任意文件）
local OPENABLE = {
  ase = true, aseprite = true, png = true, jpg = true, jpeg = true,
  gif = true, webp = true, bmp = true, pcx = true, tga = true,
}

function Workspace:isOpenable(path)
  local s = toSlash(path)
  local ext = s:match("%.([%w]+)$")
  if not ext then return false end
  ext = ext:lower()   -- 可能是中文文件名，但扩展名在末尾且是 ASCII 才安全
  if not ext:find("^[%z\1-\127]+$") then return false end
  return OPENABLE[ext] == true
end

return workspace
