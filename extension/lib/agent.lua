-- lib/agent.lua -- orchestration: panel + WebSocket + ops + versions
--
-- Protocol (JSON text frames + binary pixel frames)
--   Lua -> bridge:
--     hello        {aseprite, apiVersion, ops}
--     chat         {id, text, context}
--     ops_result   {id, ok, report | error}
--     versions     {id, list}
--     canvas_info_result {id, context}
--     upload       {id, name, width, height}   + binary RGBA
--     canvas_pixels{id, width, height}         + binary RGBA
--     request_error{id, error}
--   bridge -> Lua:
--     status       {text}
--     say          {kind, text}
--     run_ops      {id, label, ops}
--     snapshot     {id, label}
--     rollback     {id, to}
--     list_versions{id}
--     canvas_info  {id}
--     get_canvas   {id}
--     import_image {id, width, height, note}   + binary RGBA

local util = require("lib.util")
local ops = require("lib.ops")
local sizelib = require("lib.sizelib")
local versions = require("lib.versions")
local panel = require("lib.panel")
local settings = require("lib.settings")
local ws = require("lib.ws")
local i18n = require("lib.i18n")

local agent = {}
local Agent = {}
Agent.__index = Agent

-- HINT 已并入 i18n.helpText()

function agent.new(cfg)
  local self = setmetatable({
    cfg = cfg or {},
    conn = nil,
    seq = 0,
  }, Agent)

  self.panel = panel.new{
    onSend = function(text) self:sendChat(text) end,
    onAction = function(name) self:action(name) end,
    onUpload = function(path) self:upload(path) end,
    onMiniAction = function(id) return self:miniAction(id) end,
    onFixRun = function(paths) self:runFixQueue(paths) end,
  }

  -- 插件内改 API：Save/Test 都走桥，桥负责写 config.json（改完立即生效，不用重启桥）
  self.settings = settings.new{
    port = self.cfg.port,
    onSave = function(llm)
      self:send{ type = "set_config", llm = llm }
    end,
    onTest = function()
      self.panel:log(i18n.t("testing"), "info")
      self:send{ type = "test_llm" }
    end,
  }
  return self
end

-- 界面语言：Aseprite 首选项 -> 系统语言 -> 默认中文（见 i18n.resolve）
function Agent:initLanguage()
  local pref
  pcall(function() pref = app.preferences.general.language end)

  -- 语言线索，按可靠性排序：LANGUAGE（显式设的）> LANG（只认像语言标签的，
  -- 免得 Git-Bash 的 "C.UTF-8" 之类把判断带偏）> 系统全名里的英文/中文写法。
  -- 全都读不到时 i18n.resolve 兜底【中文】。
  local hints = {}
  pcall(function() hints[#hints + 1] = tostring(app.os and app.os.fullName or "") end)
  do
    local env = os.getenv("LANGUAGE")
    if env and env ~= "" then hints[#hints + 1] = tostring(env) end
    local lang = os.getenv("LANG")
    if lang and lang:sub(1, 2):lower() ~= "c." and lang ~= "C" and lang ~= "POSIX" then
      hints[#hints + 1] = tostring(lang)
    end
  end
  local osLang = table.concat(hints, " ")

  pcall(function() i18n.resolve(pref, osLang) end)
end


----------------------------------------------------------------------
-- 命令表 / 小面板的数据（文案随语言走）
----------------------------------------------------------------------

function Agent:menuCommands()
  local list = i18n.menuCommands()
  -- 动态：给"回滚"补上当前版本栈的提示
  local ok, list_versions = pcall(versions.list, app.activeSprite)
  local n = (ok and list_versions) and #list_versions or 0
  for _, c in ipairs(list) do
    if c.id == "rollback" then
      c.note = string.format("%s  (%d)", c.note, n)
    end
  end
  return list
end

-- 小面板里点了一个动作：先接管面板特有的两个（命令表 / 收起），其余交给 action()
function Agent:miniAction(id)
  if id == "close" then
    if self.panel then self.panel:hideMini() end
    return true
  end
  if id == "menu" then
    if self.panel then
      self.panel:show()
      self.panel:openMenu()
    end
    return true
  end
  return false   -- 交给 Panel:_miniAction 的兜底（onAction）
end

----------------------------------------------------------------------
-- connection
----------------------------------------------------------------------

function Agent:url()
  return "ws://127.0.0.1:" .. tostring(self.cfg.port or 8777)
end

function Agent:connect(quiet)
  if self.conn and self.conn:isOpen() then return end
  self.panel:setStatus(string.format(i18n.t("connecting"), self:url()))

  self.conn = ws.connect(self:url(), {
    onOpen = function()
      self.panel:setStatus(i18n.t("connected"))
      self.panel:log(string.format(i18n.t("bridged"), self:url()), "info")
      self:send{
        type = "hello",
        aseprite = tostring(app.version),
        apiVersion = app.apiVersion,
        ops = ops.names,
        opsHelp = ops.describe(),
      }
      self:flushPendingChats()
      self:flushPendingFixes()
    end,
    onText = function(msg) self:onMessage(msg) end,
    onBinary = function(header, data) self:onBinary(header, data) end,
    onClose = function() self.panel:setStatus(i18n.t("disconnected")) end,
    onError = function(err)
      self.panel:setStatus(i18n.t("connError"))
      self.panel:log(string.format(i18n.t("connErrorDetail"), tostring(err)), "error")
    end,
  })

  if not quiet then
    self.panel:log(i18n.t("connectingLong"), "info")
    self.panel:log("  " .. tostring(self.cfg.bridgeHint or "node bridge/src/server.mjs"), "info")
  end
end

function Agent:send(tbl)
  if not self.conn then return false end
  return self.conn:send(tbl)
end

function Agent:nextId()
  self.seq = self.seq + 1
  return self.seq
end

----------------------------------------------------------------------
-- canvas context
----------------------------------------------------------------------

function Agent:context()
  local spr = app.activeSprite
  if not spr then
    return { hasSprite = false }
  end
  local cel = app.activeCel
  local img = cel and cel.image or nil

  local layers = {}
  for i = 1, #spr.layers do layers[#layers + 1] = spr.layers[i].name end

  local ctx = {
    hasSprite = true,
    sprite = {
      name = (spr.filename ~= "" and app.fs.fileName(spr.filename)) or "(untitled)",
      width = spr.width,
      height = spr.height,
      colorMode = spr.colorMode,
      layers = layers,
      frames = #spr.frames,
    },
    layer = cel and cel.layer.name or nil,
    frame = cel and cel.frameNumber or nil,
    versionCount = versions.count(spr),
  }

  if spr.selection and not spr.selection.isEmpty then
    local b = spr.selection.bounds
    ctx.selection = { x = b.x, y = b.y, w = b.width, h = b.height }
  end

  if img and img.bytesPerPixel == 4 then
    local colors, total, opaque = ops.colorUsage(img, 12)
    ctx.colors = colors
    ctx.totalPixels = total
    ctx.opaquePixels = opaque
  end

  -- 内容包围盒 + 四周留白：AI 据此判断"这张图有多少空白" ——
  -- 留白多说明该【裁剪】，内容铺满才该【整体缩放】。省得模型自己从像素统计里推。
  local b, why = sizelib.contentBounds(spr)
  if b then
    ctx.contentBounds = b
    ctx.padding = {
      left = b.x,
      top = b.y,
      right = spr.width - (b.x + b.w),
      bottom = spr.height - (b.y + b.h),
    }
    local canvasArea = spr.width * spr.height
    ctx.contentRatio = canvasArea > 0 and (b.w * b.h / canvasArea) or 0
  else
    ctx.contentBounds = nil
    ctx.contentBoundsNote = why   -- "empty"（全透明）或 "too_large"（图太大没扫）
  end

  return ctx
end

----------------------------------------------------------------------
-- user actions
----------------------------------------------------------------------

function Agent:open()
  self:initLanguage()
  self.panel.opts.menuCommands = function() return self:menuCommands() end
  self.panel:setHint(i18n.t("hint"))
  self.panel:show()
  self:connect()
  self.panel:log(i18n.t("ready"), "info")
  self.panel:log(i18n.t("tipMenu"), "info")
end

-- 连接是异步的：用户可能在握手完成前就敲了指令。先排队，连上再发。
-- 注意：回显由面板负责（终端里输入总是显示出来），这里不要再 log 一遍。
function Agent:sendChat(text)
  if not (self.conn and self.conn:isOpen()) then
    self.pendingChats = self.pendingChats or {}
    self.pendingChats[#self.pendingChats + 1] = text
    self.panel:log(i18n.t("queued"), "info")
    return
  end
  self:sendChatNow(text)
end

function Agent:sendChatNow(text)
  self:send{
    type = "chat",
    id = self:nextId(),
    text = text,
    context = self:context(),
  }
end

function Agent:flushPendingChats()
  local queued = self.pendingChats
  self.pendingChats = nil
  if queued then
    for _, text in ipairs(queued) do self:sendChatNow(text) end
  end
end

function Agent:action(name)
  if name == "snapshot" then
    local ok, meta = pcall(versions.push, "manual snapshot", app.activeSprite)
    if ok then
      self.panel:log(string.format(i18n.t("backedUp"), meta.id, meta.label, meta.date), "tool")
    else
      self.panel:log(string.format(i18n.t("snapFailed"), tostring(meta)), "error")
    end
  elseif name == "rollback" then
    local ok, rep = pcall(versions.rollback, "last")
    if ok then
      self.panel:log(string.format(i18n.t("rolledBack"),
        rep.id, rep.label, rep.matched, rep.total), "tool")
      if #rep.missing > 0 then
        self.panel:log(string.format(i18n.t("layersGone"), table.concat(rep.missing, ", ")), "error")
      end
    else
      self.panel:log(string.format(i18n.t("rollbackFailed"), tostring(rep)), "error")
    end
  elseif name == "versions" then
    local list = versions.list(app.activeSprite)
    if #list == 0 then
      self.panel:log(i18n.t("noSnapshots"), "info")
    else
      self.panel:log(string.format(i18n.t("versionStack"), #list), "info")
      for _, m in ipairs(list) do
        self.panel:log(string.format("  v%d  %s  %s  %d cel(s)", m.id, m.date, m.label, m.cels), "info")
      end
    end
  elseif name == "reconnect" then
    if self.conn then self.conn:close() end
    self:connect()
  elseif name == "settings" then
    self.settings:show(self.config)
  elseif name == "upload" or name == "fixadd" then
    self:pickFile()                 -- 选一张 -> 进队列 -> 弹小确认窗
  elseif name == "fix" then
    if self.panel:fixQueueSize() > 0 then
      self.panel:_showFixDialog()   -- 队列里已有文件：直接把确认窗拉出来
    else
      self:pickFile()
    end
  elseif name == "help" then
    self.panel:log(i18n.helpText(), "info")
  elseif name == "menu" then
    self.panel:openMenu()
  else
    self.panel:log(string.format(i18n.t("unknownAction"), tostring(name)), "error")
  end
end

-- 让小面板也能选图：Aseprite 的 OpenFile 命令**返回布尔值（成功与否），不是文件路径**
-- （见 src/app/script/app_command_object.cpp:Command_call），所以路径要事后从
-- app.activeSprite.filename 取。选完直接送去做网格矫正（这就是「矫正图片」的本意）。
function Agent:pickFile()
  local before = app.activeSprite and app.activeSprite.filename or ""

  local ok, err = pcall(function()
    app.command.OpenFile{ ui = true }
  end)
  if not ok then
    self.panel:log(string.format(i18n.t("fileDialogFailed"), tostring(err)), "error")
    return
  end

  local spr = app.activeSprite
  local path = (spr and spr.filename) or ""
  if path == "" or path == before then
    -- 用户取消了，或者只是切了文档：不打扰
    return
  end

  self.panel:log(string.format(i18n.t("loadedFixing"), app.fs.fileName(path)), "info")
  self.panel:addFixFile(path)       -- 进队列 + 弹小确认窗（两段式：确认后才开始）
end

-- 用户在小确认窗里点了"开始矫正"：逐张跑 Perfect Pixel
function Agent:runFixQueue(paths)
  if not paths or #paths == 0 then return end
  self.pendingFixes = paths
  if not (self.conn and self.conn:isOpen()) then
    self.panel:log(i18n.t("queued"), "info")
    return
  end
  self:flushPendingFixes()
end

function Agent:flushPendingFixes()
  local q = self.pendingFixes
  self.pendingFixes = nil
  if not q then return end
  for i, path in ipairs(q) do
    self.panel:log(string.format(i18n.t("fixRunning"), i, #q, app.fs.fileName(path)), "info")
    self:upload(path, true)         -- 队列批量时后面自动串行，这里一张张发
  end
end

----------------------------------------------------------------------
-- upload an image: send its pixels to the bridge for Perfect Pixel
----------------------------------------------------------------------

function Agent:upload(path, fromQueue)
  if not fromQueue then
    self.panel:log(string.format(i18n.t("reading"), path), "info")
  end
  local ok, err = pcall(function()
    local src = Sprite{ fromFile = path }
    if not src then error("cannot read that file (unsupported format?)") end
    local cel = src.cels[1]
    local img = cel and cel.image
    if not img then error("that file has no readable pixels") end

    local w, h = img.width, img.height
    local data
    if img.bytesPerPixel == 4 then
      data = img.bytes
    else
      local tmp = Image(w, h, ColorMode.RGB)
      tmp:drawImage(img, Point(0, 0), 255, BlendMode.SRC)
      data = tmp.bytes
    end

    self.panel:log(string.format(i18n.t("loadedSending"), w, h), "info")
    local id = self:nextId()
    self.conn:sendBinary({ type = "upload", id = id, name = app.fs.fileName(path),
                           width = w, height = h }, data)
  end)
  if not ok then
    self.panel:log(string.format(i18n.t("readFailed"), tostring(err)), "error")
  end
end

----------------------------------------------------------------------
-- send current canvas pixels (for "fix the canvas I have open")
----------------------------------------------------------------------

function Agent:sendCanvas(id)
  local spr = app.activeSprite
  local cel = app.activeCel
  local img = cel and cel.image
  if not spr or not img then
    self:send{ type = "request_error", id = id, error = "no readable canvas content" }
    return
  end

  local data
  if img.bytesPerPixel == 4 then
    data = img.bytes
  else
    local tmp = Image(img.width, img.height, ColorMode.RGB)
    tmp:drawImage(img, Point(0, 0), 255, BlendMode.SRC)
    data = tmp.bytes
  end

  self.conn:sendBinary({
    type = "canvas_pixels", id = id,
    width = img.width, height = img.height,
  }, data)
end

----------------------------------------------------------------------
-- messages from the bridge
----------------------------------------------------------------------

function Agent:onMessage(msg)
  local t = msg.type

  if t == "status" then
    self.panel:setStatus(msg.text or "")

  elseif t == "say" then
    self.panel:log(msg.text or "", msg.kind or "ai")

  elseif t == "clear" then
    self.panel:clear()

  elseif t == "config" then
    self.config = msg.llm or {}
    self.settings:_fill(self.config)
    self.panel:log(string.format(
      "Settings: model=%s  baseURL=%s  apiKey=%s",
      self.config.model ~= "" and self.config.model or "(unset)",
      self.config.baseUrl ~= "" and self.config.baseUrl or "(unset)",
      self.config.apiKeySet and ("set " .. tostring(self.config.apiKeyHint or "")) or "NOT SET"), "info")

  elseif t == "run_ops" then
    self:runOps(msg)

  elseif t == "snapshot" then
    local ok, res = pcall(versions.push, msg.label or "AI snapshot", app.activeSprite)
    self:send{ type = "snapshot_result", id = msg.id, ok = ok,
               meta = ok and res or nil, error = (not ok) and tostring(res) or nil }

  elseif t == "rollback" then
    local ok, res = pcall(versions.rollback, msg.to)
    self:send{ type = "rollback_result", id = msg.id, ok = ok,
               report = ok and res or nil, error = (not ok) and tostring(res) or nil }

  elseif t == "list_versions" then
    self:send{ type = "versions", id = msg.id, list = versions.list(app.activeSprite) }

  elseif t == "canvas_info" then
    self:send{ type = "canvas_info_result", id = msg.id, context = self:context() }

  elseif t == "crop" or t == "scale" or t == "canvas_size" then
    self:sizeOp(t, msg)

  elseif t == "get_canvas" then
    self:sendCanvas(msg.id)

  elseif t == "import_image" then
    self.pendingImport = msg   -- binary frame follows

  else
    self.panel:log(string.format(i18n.t("unknownMessage"), tostring(t)), "error")
  end
end

function Agent:onBinary(header, data)
  if header.type == "import_image" then
    self:importImage(header, data)
  else
    self.panel:log(string.format(i18n.t("unexpectedFrame"), tostring(header.type)), "error")
  end
end

-- Execute the ops the model asked for. Auto-backup first.
function Agent:runOps(msg)
  local list = msg.ops or {}
  local label = msg.label or "AI edit"
  local id = msg.id

  local okSnap, meta = pcall(versions.push, "before: " .. label, app.activeSprite)
  if okSnap then
    self.panel:log(string.format(i18n.t("autoBacked"), meta.id, meta.label), "tool")
  end

  local ok, res = pcall(ops.run, list, label)
  if ok then
    local parts = {}
    for _, r in ipairs(res.ops) do
      parts[#parts + 1] = string.format("%s %dpx", r.op, r.changed)
    end
    self.panel:log(string.format(i18n.t("applied"),
      #res.ops, res.layer, table.concat(parts, ", ")), "tool")
    self:send{ type = "ops_result", id = id, ok = true, report = res }
  else
    self.panel:log(string.format(i18n.t("opsFailed"), tostring(res)), "error")
    self:send{ type = "ops_result", id = id, ok = false, error = tostring(res) }
  end
end

-- 文档级几何操作：裁剪 / 整体缩放 / 改画布尺寸。
-- 和 runOps 一样先自动备份；失败时画布不动，把原因回给模型。
function Agent:sizeOp(kind, msg)
  local spr = app.activeSprite
  local id = msg.id

  if not spr then
    self:send{ type = "size_result", id = id, ok = false, error = "no document is open" }
    return
  end

  local label = msg.label or kind
  local okSnap, meta = pcall(versions.push, "before: " .. label, spr)
  if okSnap then
    self.panel:log(string.format(i18n.t("autoBacked"), meta.id, meta.label), "tool")
  end

  local ok, res = pcall(function()
    if kind == "crop" then
      return sizelib.crop(spr, msg.x, msg.y, msg.w, msg.h)
    elseif kind == "scale" then
      return sizelib.scale(spr, msg.width, msg.height, msg.method)
    else
      return sizelib.canvasSize(spr, msg.width, msg.height, msg.anchor)
    end
  end)

  if ok then
    if res.changed then
      self.panel:log(string.format(i18n.t("sizeDone"), kind, res.from, res.to), "tool")
    else
      self.panel:log(string.format(i18n.t("sizeNoop"), kind, res.note or ""), "info")
    end
    self:send{ type = "size_result", id = id, ok = true, report = res }
  else
    self.panel:log(string.format(i18n.t("sizeFailed"), tostring(res)), "error")
    self:send{ type = "size_result", id = id, ok = false, error = tostring(res) }
  end
end

-- Build a new document from the pixels the bridge sent back.
function Agent:importImage(header, data)  local w, h = header.width, header.height
  if not w or not h or #data ~= w * h * 4 then
    self.panel:log(string.format(i18n.t("importMismatch"),
      #data, (w or 0) * (h or 0) * 4), "error")
    return
  end

  local ok, err = pcall(function()
    app.command.NewFile{ width = w, height = h, colorMode = ColorMode.RGB }
    local img = app.activeCel.image
    local scratch = Image(w, h, ColorMode.RGB)
    scratch.bytes = data
    app.transaction("AI: import fixed image", function()
      img:drawImage(scratch, Point(0, 0), 255, BlendMode.SRC)
    end)
  end)

  if ok then
    self.panel:log(string.format(i18n.t("openedDoc"),
      w, h, header.note and ("  (" .. header.note .. ")") or ""), "ai")
    self.panel:log(i18n.t("blurry"), "info")
  else
    self.panel:log(string.format(i18n.t("importFailed"), tostring(err)), "error")
  end
end

----------------------------------------------------------------------

function Agent:destroy()
  if self.conn then self.conn:close() end
  if self.settings then self.settings:destroy() end
  if self.panel then self.panel:destroy() end
end

return agent
