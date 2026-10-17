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
local artlib = require("lib.artlib")
local versions = require("lib.versions")
local pixfix = require("lib.pixfix")
local panel = require("lib.panel")
local settings = require("lib.settings")
local ws = require("lib.ws")
local i18n = require("lib.i18n")
local workspace = require("lib.workspace")

local agent = {}
local Agent = {}
Agent.__index = Agent

----------------------------------------------------------------------
-- 算子的两个来源：lib.ops（内建实现）+ registry 的 op（能力包注册的）
--
-- 为什么要并：能力包注册的算子若既不上报给桥、也不被执行，"模型能给自己加能力"
-- 就只成立一半 —— 它写得出来，自己却看不见、也跑不了。
-- 分工：lib.ops 仍是内建算子的唯一实现；registry 只负责"还有哪些算子存在"。
----------------------------------------------------------------------

local LEGACY_OP = {}
for _, n in ipairs(ops.names) do LEGACY_OP[n] = true end

-- 名字 -> spec：registry 里没有 op 时返回 nil（老路径、无内核时都走这里）
function agent.packOp(kernel, name)
  if not (kernel and kernel.registry and kernel.registry.get) then return nil end
  local ok, spec = pcall(function() return kernel.registry:get("op", tostring(name)) end)
  if ok and type(spec) == "table" then return spec end
  return nil
end

-- 这个算子是"能力包注册的"吗？判据是「registry 有、且 lib.ops 不能跑」
-- —— 两边都有的名字仍归 lib.ops，这样内建算子的批量事务语义不会被打散。
function agent.isPackOp(kernel, name)
  name = tostring(name or "")
  if name == "" or LEGACY_OP[name] then return false end
  return agent.packOp(kernel, name) ~= nil
end

function agent.opNames(kernel)
  local seen, out = {}, {}
  if kernel and kernel.registry and kernel.registry.list then
    local ok, list = pcall(function() return kernel.registry:list("op") end)
    if ok and type(list) == "table" then
      for _, spec in ipairs(list) do
        local name = spec and (spec.name or spec.id) or nil
        if name ~= nil then
          name = tostring(name)
          if name ~= "" and not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
      end
    end
  end
  for _, name in ipairs(ops.names) do
    if not seen[name] then seen[name] = true; out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

-- 给模型看的能力说明：内建那 10 条的原文不动，包算子追加在后面
function agent.opsHelp(kernel)
  local parts = { ops.describe() }
  local line = {}
  if kernel and kernel.registry and kernel.registry.list then
    local ok, list = pcall(function() return kernel.registry:list("op") end)
    if ok and type(list) == "table" then
      for _, spec in ipairs(list) do
        local name = tostring(spec and (spec.name or spec.id) or "")
        if name ~= "" and not LEGACY_OP[name] then
          line[#line + 1] = string.format("- %s：%s（能力包注册）", name, tostring(spec.label or name))
        end
      end
    end
  end
  if #line > 0 then parts[#parts + 1] = table.concat(line, "\n") end
  return table.concat(parts, "\n")
end

-- 执行一串算子请求：能力包注册的走 kernel:invoke（带沙箱预算），其余仍走 lib.ops。
-- 顺序按请求原序；**连续的内建算子合并成一个事务**，所以纯内建请求的撤销粒度
-- 与 v0.5.x 一字不差（一个请求一步撤销）。
-- 返回值形状与 lib.ops.run 相同：{ sprite, frame, ops = {...}, layer | layers, hint }
function agent.execOps(list, label, cels, kernel)
  if type(list) ~= "table" or #list == 0 then error("nothing to execute") end

  local out = { ops = {} }
  local firstCel = type(cels) == "table" and cels[1] or cels
  if firstCel then
    out.layer = firstCel.layer and firstCel.layer.name or nil
    out.frame = firstCel.frameNumber
    local okName, base = pcall(function()
      local sp = firstCel.sprite
      if not sp or sp.filename == "" then return nil end
      return app.fs.fileName(sp.filename)
    end)
    out.sprite = (okName and base) or "(未命名)"
  end

  local i = 1
  while i <= #list do
    local one = list[i]
    local name = tostring(one.op or one.type or "")
    if agent.isPackOp(kernel, name) then
      local params = {}
      for k, v in pairs(one) do
        if k ~= "op" and k ~= "type" then params[k] = v end
      end
      local ok, res = kernel:invoke("op", name, kernel.host, params)
      if not ok then
        -- 超时/抛错都折成可读错误，交给上层的 pcall 回给模型自愈
        error(string.format("op %s: %s", name, tostring(res)), 0)
      end
      res = type(res) == "table" and res or {}
      out.ops[#out.ops + 1] = {
        op = name,
        changed = tonumber(res.changed) or 0,
        elided = res.elided == true,
        detail = res.detail,
      }
      i = i + 1
    else
      local batch = {}
      while i <= #list do
        local n = tostring(list[i].op or list[i].type or "")
        if agent.isPackOp(kernel, n) then break end
        batch[#batch + 1] = list[i]
        i = i + 1
      end
      local rep = ops.run(batch, label, cels)
      for _, r in ipairs(rep.ops or {}) do out.ops[#out.ops + 1] = r end
      if out.layers == nil and rep.layers ~= nil then out.layers = rep.layers; out.scope = rep.scope end
      if out.layer == nil and rep.layer ~= nil then out.layer = rep.layer end
      if out.hint == nil and rep.hint ~= nil then out.hint = rep.hint end
      if out.sprite == nil then out.sprite = rep.sprite end
      if out.frame == nil then out.frame = rep.frame end
    end
  end

  -- "一个像素都没改"的提示只在真的全局没改时才成立
  local changed = 0
  for _, r in ipairs(out.ops) do changed = changed + (tonumber(r.changed) or 0) end
  if changed > 0 then out.hint = nil end
  return out
end

-- HINT 已并入 i18n.helpText()

function agent.new(cfg)
  local self = setmetatable({
    cfg = cfg or {},
    conn = nil,
    seq = 0,
    pendingAskId = nil,      -- P7：正在等用户回答的提问 id
    pendingAskOptions = nil,
    pendingApply = nil,      -- 待应用的矫正结果（面板「应用这个结果」按钮用）
  }, Agent)

  self.panel = panel.new{
    onSend = function(text) self:sendChat(text) end,
    onAction = function(name, arg) self:action(name, arg) end,
    onLog = function(kind, text) self:send{ type = "log", kind = kind, text = text } end,
    onUpload = function(path) self:upload(path) end,
    onMiniAction = function(id) return self:miniAction(id) end,
    onFixRun = function(paths) self:runFixQueue(paths) end,
    onAskAnswer = function(index) self:answerAsk(index) end,
    onModeChange = function(mode) self:saveUi(mode) end,
    frameImage = function() return self:frameImage() end,
    onThinkingChange = function(v) self:setThinking(v) end,
  }

  -- 工作文件夹（P10）：备份 / 副本 / 打开 / 交付都交给它。
  -- root 从桥推来的 config 里取（workspace.root），空 = 工作区模式关闭（现状行为）。
  self.workspace = workspace.new{
    getRoot = function() return self.workspaceRoot or "" end,
    log = function(text, kind) self.panel:log(text, kind) end,
  }

  -- 插件内改 API：Save/Test 都走桥，桥负责写 config.json（改完立即生效，不用重启桥）
  self.settings = settings.new{
    port = self.cfg.port,
    wsRoot = self.workspaceRoot or "",
    barBg = self.uiBarBg or "",
    onSave = function(llm, wsRoot, barBg)
      self.uiBarBg = barBg or ""
      self.lastUiMode = nil                     -- 强制回写一次，把底色也带上
      self.panel:setBarColor(self.uiBarBg)
      self:send{
        type = "set_config",
        llm = llm,
        workspace = { root = wsRoot or "" },
        ui = { mode = self.panel:layoutMode(), barBg = self.uiBarBg },
      }
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

-- ---- 连接重试 ----------------------------------------------------------
-- 为什么必须重试：桥是 main.lua 异步拉起来的（start /MIN cmd /c node …），
-- 真正开始监听要 1~2 秒。面板一打开就连必然被拒 —— 只连一次的结果就是
-- 永久停在"未连接"，用户看到的就是"无法连接桥"。
local RETRY_DELAY = 1.0
local RETRY_MAX = 6

agent.connectRetryDefaults = { delay = RETRY_DELAY, max = RETRY_MAX }

local function defaultAfter(seconds, fn)
  local ok, timer = pcall(function()
    local t = Timer{ interval = seconds, ontick = function(self2) self2:stop(); fn() end }
    t:start()
    return t
  end)
  if ok then return timer end
  return nil
end

function Agent:_retryPolicy()
  local c = (self.cfg and self.cfg.connectRetry) or {}
  return tonumber(c.delay) or RETRY_DELAY, tonumber(c.max) or RETRY_MAX
end

-- 只清"排队中的下一次尝试"与在途回调，不动"还剩几次"
function Agent:_cancelTimer()
  self._retryToken = (self._retryToken or 0) + 1
  local h = self._retryHandle
  self._retryHandle = nil
  if h and h ~= true then
    if self.cfg and type(self.cfg.cancelTimer) == "function" then
      pcall(self.cfg.cancelTimer, h)
    else
      pcall(function() h:stop() end)
    end
  end
end

function Agent:cancelRetry()
  self:_cancelTimer()
  self._retryLeft = 0
  self._retrying = false
end

-- 对外入口：连一次失败就按退避重试，连上即停。面板/工作台的"重试"也走这里。
function Agent:connect(quiet)
  self:_cancelTimer()
  local _, max = self:_retryPolicy()
  self._retryLeft = max
  self._retrying = true
  self._retryQuiet = quiet and true or false
  self:_attempt(quiet)
end

function Agent:_attempt(quiet)
  self:_cancelTimer()
  if self.conn and self.conn:isOpen() then
    self:cancelRetry()
    return
  end
  if self.conn then
    pcall(function() self.conn:close() end)
    self.conn = nil
  end

  -- 每次尝试一个 id：旧 conn 的迟到回调（onClose/onError）不许再排下一次
  self._attemptId = (self._attemptId or 0) + 1
  local attemptId = self._attemptId
  local function current() return attemptId == self._attemptId end

  self.panel:setStatus(string.format(i18n.t("connecting"), self:url()), "busy", self:docName())

  local wsMod = (self.cfg and self.cfg.ws) or ws
  local conn = wsMod.connect(self:url(), {
    onOpen = function()
      if not current() then return end
      self:cancelRetry()                     -- 连上即停，别再排下一次
      self.panel:setStatus(i18n.t("connected"), "ok", self:docName())
      self.panel:log(string.format(i18n.t("bridged"), self:url()), "info")
      self:send{
        type = "hello",
        aseprite = tostring(app.version),
        apiVersion = app.apiVersion,
        -- 并集：registry（含能力包注册的）+ lib.ops。少了这一半，模型看不见自己的新算子
        ops = agent.opNames(self:kernel()),
        opsHelp = agent.opsHelp(self:kernel()),
      }
      self:_flushControl()          -- 离线期间积压的控制帧（hello 已先发）
      self:flushPendingChats()      -- 再发聊天：顺序 hello → 控制帧 → 聊天
      self:flushPendingFixes()
      if (self._droppedLogs or 0) > 0 then
        self.panel:log(string.format("离线期间有 %d 条日志未送达（不影响对话）", self._droppedLogs), "info")
        self._droppedLogs = 0
      end
    end,
    onText = function(msg) if current() then self:onMessage(msg) end end,
    onBinary = function(header, data) if current() then self:onBinary(header, data) end end,
    onClose = function()
      if not current() then return end
      self.panel:setStatus(i18n.t("disconnected"), "error")
      if self._retrying then self:_scheduleNextAttempt() end
    end,
    onError = function(err)
      if not current() then return end
      if self._retrying then
        -- 重试期间失败是预期的（桥还没监听），别刷成红色错误
        self.panel:log(string.format(i18n.t("connErrorDetail"), tostring(err)), "info")
        self:_scheduleNextAttempt()
      else
        self.panel:setStatus(i18n.t("connError"), "error")
        self.panel:log(string.format(i18n.t("connErrorDetail"), tostring(err)), "error")
      end
    end,
  })
  self.conn = conn

  if not quiet then
    self.panel:log(i18n.t("connectingLong"), "info")
    self.panel:log("  " .. tostring(self.cfg.bridgeHint or "node bridge/src/server.mjs"), "info")
  end
end

function Agent:_scheduleNextAttempt()
  if self._retryHandle then return end        -- onError 与 onClose 可能都来，只排一次
  local delay, max = self:_retryPolicy()
  local left = self._retryLeft or 0
  if left <= 1 then
    self._retrying = false
    self._retryLeft = 0
    self.panel:setStatus(i18n.t("connError"), "error")
    self.panel:log(string.format("!! %d 次尝试都没连上桥（%s）。", max, self:url()), "error")
    self.panel:log("   桥可能还没起来，或 Node.js 没装（node --version 能查）。", "error")
    self.panel:log("   确认后在命令表里执行「重连」再试一次。", "error")
    self.panel:log("   手动起桥: " .. tostring(self.cfg and self.cfg.bridgeHint or "node bridge/src/server.mjs"), "info")
    return
  end
  self._retryLeft = left - 1
  local attemptNo = max - self._retryLeft
  self.panel:log(string.format("桥还没就绪，%.0f 秒后重试（第 %d/%d 次）…", delay, attemptNo, max), "info")

  local token = self._retryToken or 0
  local after = (self.cfg and type(self.cfg.after) == "function") and self.cfg.after or defaultAfter
  local quiet = self._retryQuiet
  self._retryHandle = true                    -- 占位，防止 after 同步触发时重复排队
  local handle = after(delay, function()
    if (self._retryToken or 0) ~= token then return end
    self._retryHandle = nil
    self:_attempt(quiet)
  end)
  if self._retryHandle == true then self._retryHandle = handle end
end

-- ---- 统一发送闸门 ------------------------------------------------------
-- 真机日志里那行红字（lib/ws.lua:125 WebSocket is not connected, can't send text）
-- 就是"socket 还没 open 就 send"：conn:send 直接抛，异常一路甩进会话区。
-- 所有发送点因此统一走这道闸门：能发就发，不能发就排队（log 帧丢弃），绝不抛。
local SEND_QUEUE_MAX = 32

function Agent:_isOpen()
  local conn = self.conn
  if not conn then return false end
  local ok, open = pcall(function() return conn:isOpen() end)
  return ok and open == true
end

function Agent:_pendingQueue()
  if not self._pendingSend then self._pendingSend = {} end
  return self._pendingSend
end

function Agent:_enqueue(item)
  local q = self:_pendingQueue()
  while #q >= SEND_QUEUE_MAX do table.remove(q, 1) end   -- 离线太久就丢最老的，别无限堆
  q[#q + 1] = item
end

function Agent:_safeSend(tbl)
  if type(tbl) ~= "table" then return false end
  if self:_isOpen() then
    local ok, err = pcall(self.conn.send, self.conn, tbl)
    if ok then return true end
    -- isOpen 说开、底层其实已经死了：退化成排队，别把异常甩出去
    self._lastSendError = tostring(err)
  end

  local kind = tostring(tbl.type or "")
  if kind == "log" then
    -- 离线期间的日志帧没有重放价值，而且是刷屏源头：丢掉并计数
    self._droppedLogs = (self._droppedLogs or 0) + 1
    return false
  end
  self:_enqueue({ kind = "text", tbl = tbl })
  return false
end

function Agent:_safeSendBinary(header, data)
  if type(header) ~= "table" then return false end
  if self:_isOpen() then
    local ok, err = pcall(self.conn.sendBinary, self.conn, header, data)
    if ok then return true end
    self._lastSendError = tostring(err)
  end
  self:_enqueue({ kind = "binary", header = header, data = data })
  return false
end

-- 连上后的补发顺序：hello（onOpen 里先发）→ 积压的控制帧 → 待发聊天
function Agent:_flushControl()
  local q = self._pendingSend
  if not q or #q == 0 then return 0 end
  if not self:_isOpen() then return 0 end

  local keep, sent = {}, 0
  for _, item in ipairs(q) do
    local ok
    if item.kind == "binary" then
      ok = pcall(self.conn.sendBinary, self.conn, item.header, item.data)
    else
      ok = pcall(self.conn.send, self.conn, item.tbl)
    end
    if ok then sent = sent + 1 else keep[#keep + 1] = item end
  end
  self._pendingSend = keep
  if sent > 0 then
    self.panel:log(string.format("已补发离线期间积压的 %d 条消息", sent), "info")
  end
  return sent
end

-- 对外保持原签名：所有 self:send{...} 都自动过闸门
function Agent:send(tbl)
  return self:_safeSend(tbl)
end

function Agent:nextId()
  self.seq = self.seq + 1
  return self.seq
end

-- 界面形态/栏底色回写（G3/G5）。只在形态真的变了的时候发，免得和启动恢复打架。
function Agent:saveUi(mode)
  mode = mode or self.panel:layoutMode()
  if mode == self.lastUiMode then return end
  self.lastUiMode = mode
  self:send{ type = "set_config", ui = { mode = mode, barBg = self.uiBarBg or "" } }
end

-- 状态栏要显示"正在改哪个文件"（P5a）。未保存的新文档显示 (untitled)。
-- 工作区模式下正在编辑副本时，后缀标出来，用户一眼知道现在改的是副本（P10）。
function Agent:docName()
  local spr = app.activeSprite
  -- 换了文档：缩略图必须重建（用户自己切标签页也一样）
  if (self.lastDocObj ~= spr) then
    self.lastDocObj = spr
    self:invalidateFrame()
  end
  if not spr then return "" end
  if spr.filename and spr.filename ~= "" then
    local name = app.fs.fileName(spr.filename)
    if self.workspace and self.workspace:isCopy(spr) then
      return name .. " " .. i18n.t("wsCopyTag")
    end
    return name
  end
  return "(untitled)"
end

-- 改画布之前的工作区准备（P10）。返回 false = 这次编辑必须中止。
-- 工作区没开时直接放行（保持现状行为）。
function Agent:prepareEdit(what)
  if not self.workspace or not self.workspace:enabled() then return true end

  local rep = self.workspace:prepare(app.activeSprite)
  if rep.skipped then return true end
  if rep.ok then return true end

  -- 任何一步失败都中止本次编辑，并让桥知道（否则模型会以为改成功了）
  self.panel:log(tostring(rep.error), "error")
  self:send{ type = "edit_blocked", what = what, error = tostring(rep.error) }
  return false
end

-- 交付（P10）：弹四个选项，选完执行
function Agent:deliver()
  local ws = self.workspace
  if not ws then return end
  if not ws:enabled() then
    self.panel:log(i18n.t("wsDisabled"), "info")
    return
  end
  if not ws:hasPending() then
    self.panel:log(i18n.t("wsNothingPending"), "info")
    return
  end

  local labels = ws:deliverLabels()
  local ids = workspace.DELIVER_CHOICES
  self.panel:showDeliverDialog(labels, function(pick)
    if pick == "cancel" then return end
    local choice = ids[pick]
    local rep = ws:deliver(choice)
    if not rep.ok then
      self.panel:log(tostring(rep.error), "error")
    end
    self.panel:setStatus(i18n.t("readyStatus"), "ok", self:docName())
  end)
end

-- 按路径打开文档（P11）
function Agent:openDocument(msg)
  local id = msg.id
  local ws = self.workspace
  local path, err = ws:resolve(msg.path)
  if not path then
    self:send{ type = "open_doc_result", id = id, ok = false, error = tostring(err) }
    return
  end
  if not ws:isOpenable(path) then
    local why = string.format(i18n.t("wsOpenDocBadExt"), tostring(path))
    self.panel:log(why, "error")
    self:send{ type = "open_doc_result", id = id, ok = false, error = why }
    return
  end

  -- 先试读：读不了就直接报错，别让 Aseprite 弹它自己的原生错误框
  local readable, readErr = pcall(function()
    local probe = Sprite{ fromFile = path }
    if not probe then error("unreadable") end
    return probe
  end)
  if not readable then
    local why = string.format(i18n.t("wsOpenDocFailed"), tostring(path), tostring(readErr))
    self.panel:log(why, "error")
    self:send{ type = "open_doc_result", id = id, ok = false, error = why }
    return
  end

  local ok, openErr = pcall(function() app.command.OpenFile{ filename = path, ui = false } end)
  local spr = app.activeSprite
  if not ok or not spr then
    local why = string.format(i18n.t("wsOpenDocFailed"), tostring(path), tostring(openErr))
    self.panel:log(why, "error")
    self:send{ type = "open_doc_result", id = id, ok = false, error = why }
    return
  end

  self.panel:log(string.format(i18n.t("wsOpened"), app.fs.fileName(spr.filename), spr.width, spr.height), "tool")
  self:send{ type = "open_doc_result", id = id, ok = true,
             name = app.fs.fileName(spr.filename), path = tostring(spr.filename),
             width = spr.width, height = spr.height }
end

-- 紧急中断（P3）：告诉桥"这一轮别跑了"。
-- 中断是 Lua -> 桥方向的单程消息，桥收到后 abort 掉当前的 fetch 和工具循环。
function Agent:abort()
  if not (self.conn and self.conn:isOpen()) then
    self.panel:log(i18n.t("abortNothing"), "info")
    return
  end
  self:send{ type = "abort" }
  self.panel:log(i18n.t("abortSent"), "info")
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

-- 底边栏缩略图用的"整幅合成图"。
--
-- 坑：`sprite:flatten()` 是【破坏性的】—— 实测 2 层会真的被合成成 1 层
-- （见 tests/lua/_quant_api2_probe.lua 的 B 段）。所以这里自己按层合成到一张
-- 游离 Image 上，只画可见层的当前帧。近似：忽略图层混合模式与不透明度（缩略图够用）。
function Agent:frameImage()
  local spr = app.activeSprite
  if not spr then return nil end
  local frameNo = 1
  pcall(function() frameNo = app.frame and app.frame.frameNumber or 1 end)
  local key = table.concat({
    tostring(spr.filename), tostring(spr.width), tostring(spr.height),
    tostring(#spr.layers), tostring(frameNo), tostring(self.frameDirty or 0),
  }, "|")
  if self.frameCache and self.frameCache.key == key then return self.frameCache.img end

  local img = Image(spr.width, spr.height, ColorMode.RGB)
  for _, layer in ipairs(spr.layers) do
    if layer.isVisible then
      local cel
      pcall(function() cel = layer:cel(frameNo) end)
      if cel and cel.image then
        pcall(function() img:drawImage(cel.image, cel.position.x, cel.position.y) end)
      end
    end
  end
  self.frameCache = { key = key, img = img }
  return img
end

-- 画布变了就把合成图作废（下次要缩略图时重建）
function Agent:invalidateFrame()
  self.frameDirty = (self.frameDirty or 0) + 1
  self.frameCache = nil
end

-- 栏里的滑杆改了思考强度：立刻写回桥的配置（空 apiKey 不算改动，见 set_config）
function Agent:setThinking(value)
  self.thinking = tostring(value or "auto")
  if not (self.conn and self.conn:isOpen()) then
    self.panel:log(i18n.t("ctxFailed"), "error")
    return
  end
  self:send{ type = "set_config", llm = { thinking = self.thinking } }
  self.panel:log(string.format(i18n.t("thinkChanged"), self.thinking), "info")
end

-- 清空对话上下文（桥侧的历史 + 摘要）。没连上就没法清：桥才是记忆的持有者。
function Agent:resetHistory()
  if not (self.conn and self.conn:isOpen()) then
    self.panel:log(i18n.t("ctxFailed"), "error")
    return
  end
  self:send{ type = "reset_history", id = self:nextId() }
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

function Agent:action(name, arg)
  -- 对话表里挑了一行（id 形如 conv:3）—— 序号由桥去认，面板只管转发
  if type(name) == "string" and name:sub(1, 5) == "conv:" then
    local idx = tonumber(name:sub(6)) or 0
    if self.conn and self.conn:isOpen() then
      self:send{ type = "conversation_switch", id = self:nextId(), target = idx }
    else
      self.panel:log(i18n.t("convFailed"), "error")
    end
    return
  end
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
  elseif name == "abort" then
    self:abort()
  elseif name == "deliver" then
    self:deliver()
  elseif name == "apply_result" then
    self:applyPendingFixed()
  elseif name == "reset_history" then
    self:resetHistory()
  elseif name == "gaps" then
    if self.conn and self.conn:isOpen() then
      self:send{ type = "gaps_info", id = self:nextId() }
    else
      self.panel:log(i18n.t("gapsFailed"), "error")
    end
  elseif name == "ctx_info" then
    if self.conn and self.conn:isOpen() then
      self:send{ type = "history_info", id = self:nextId() }
    else
      self.panel:log(i18n.t("ctxFailed"), "error")
    end
  elseif name == "conversations" then
    if self.conn and self.conn:isOpen() then
      self:send{ type = "conversation_list", id = self:nextId() }
    else
      self.panel:log(i18n.t("convFailed"), "error")
    end
  elseif name == "conversation_new" then
    if self.conn and self.conn:isOpen() then
      self:send{ type = "conversation_new", id = self:nextId() }
    else
      self.panel:log(i18n.t("convFailed"), "error")
    end
  elseif name == "conversation_rename" then
    if arg then
      self:send{ type = "conversation_rename", id = self:nextId(), title = tostring(arg) }
    else
      -- 没带名字 = 先问一句，下一行输入就是名字（不做前缀匹配，见 panel.lua 的注释）
      self.panel:setPendingInput("conversation_rename", i18n.t("convRenameAsk"),
        function(t) return t ~= "" and t ~= "x" and t ~= "X" and t ~= "取消" end)
    end
  elseif name == "conversation_delete" then
    if arg then
      self:send{ type = "conversation_delete", id = self:nextId() }
    else
      self.panel:setPendingInput("conversation_delete", i18n.t("convDeleteAsk"),
        function(t)
          local s = tostring(t):lower()
          return s == "确认" or s == "确定" or s == "删除" or s == "是" or s == "yes" or s == "y"
        end)
    end
  elseif name == "bar" then
    self.panel:cycleMode()
  elseif name == "open_file" or name == "open_doc_pick" then
    self:openFilePicker()
  elseif name == "open_doc" then
    -- 没有路径参数：提示用户怎么用（真正打开是模型调 open_document 工具）
    self.panel:log(i18n.t("openDocHint"), "info")
  elseif name == "settings" then
    self.settings:show(self.config, self.workspaceRoot or "", self.uiBarBg or "")
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

-- 「打开文件…」（G4）：走 Aseprite 原生选择器，**只打开**，不进矫正队列。
-- 和 pickFile 的区别就是最后那一步：pickFile 会把文件推进矫正队列。
function Agent:openFilePicker()
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
    return                          -- 用户取消了，或者只是切了文档：不打扰
  end

  self.panel:log(string.format(i18n.t("wsOpened"), app.fs.fileName(path),
    spr.width, spr.height), "tool")
  self.panel:setStatus(i18n.t("readyStatus"), "ok", self:docName())
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
  -- 工作区开启时：先把图复制进 <root>/uploads/，之后一切操作都针对复制件，
  -- 原图一个字节都不动（P13）
  if self.workspace and self.workspace:enabled() then
    local copied, cerr = self.workspace:copyIn(path)
    if copied then
      if copied ~= path then
        self.panel:log(string.format(i18n.t("wsCopiedIn"), app.fs.fileName(copied)), "info")
      end
      path = copied
    else
      self.panel:log(string.format(i18n.t("readFailed"), tostring(cerr)), "error")
      return
    end
  end

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
    self:_safeSendBinary({ type = "upload", id = id, name = app.fs.fileName(path),
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

  self:_safeSendBinary({
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
    -- kind 决定状态栏配色（busy/tool/ok/error）；docName 显示当前文件（P5a）
    self.panel:setStatus(msg.text or "", msg.kind, self:docName())

  elseif t == "say" then
    -- 桥可以带 i18n 键，让面板用本地化文案显示（中断/超时这类固定文案）；
    -- 带 %d 的还配一份 i18nArgs，格式化成中文也一样把数字填回去
    self.panel:log(i18n.render(msg.i18n, msg.i18nArgs, msg.text or ""), msg.kind or "ai")

  elseif t == "thinking" then
    -- 模型的思考是独立帧：用弱化色（think→dim）显示，既不混进正文、也不再被丢掉
    self.panel:log(msg.text or "", "think")

  elseif t == "clear" then
    self.panel:clear()

  elseif t == "config" then
    self.config = msg.llm or {}
    if msg.workspace and type(msg.workspace.root) == "string" then
      self.workspaceRoot = msg.workspace.root
      if self.workspace then self.workspace:setRoot(self.workspaceRoot) end
    end
    if type(msg.llm.thinking) == "string" then
      self.thinking = msg.llm.thinking
      self.panel:setThinking(msg.llm.thinking)
    end
    -- 界面形态和栏底色（G3/G5）：桥记得，重启 Aseprite 也恢复
    if msg.ui then
      if type(msg.ui.mode) == "string" and msg.ui.mode ~= "" then
        self.panel:setMode(msg.ui.mode, true)     -- quiet：别在启动日志里刷一行
      end
      if type(msg.ui.barBg) == "string" then
        self.uiBarBg = msg.ui.barBg
        self.panel:setBarColor(msg.ui.barBg)
      end
    end
    self.settings:_fill(self.config, self.workspaceRoot)
    self.panel:log(string.format(
      "Settings: model=%s  baseURL=%s  apiKey=%s",
      self.config.model ~= "" and self.config.model or "(unset)",
      self.config.baseUrl ~= "" and self.config.baseUrl or "(unset)",
      self.config.apiKeySet and ("set " .. tostring(self.config.apiKeyHint or "")) or "NOT SET"), "info")

  elseif t == "run_ops" then
    if not self:prepareEdit("run_ops") then return end
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
    if not self:prepareEdit(t) then return end
    self:sizeOp(t, msg)

  elseif t == "new_sprite" or t == "add_layer" or t == "draw_art" then
    -- new_sprite 开的是全新文档，没有"改坏原文件"的风险，不需要副本
    if t ~= "new_sprite" and not self:prepareEdit(t) then return end
    self:artOp(t, msg)

  elseif t == "ask" then
    self:askUser(msg)

  elseif t == "gaps_result" then
    if (msg.entries or 0) == 0 then
      self.panel:log(i18n.t("gapsNone"), "info")
    else
      self.panel:log(string.format(i18n.t("gapsReport"), msg.entries or 0, msg.mentions or 0), "info")
      self.panel:log(string.format(i18n.t("gapsWhere"), tostring(msg.file or "")), "info")
      local last = msg.recent and msg.recent[#msg.recent]
      if last and last.request then
        self.panel:log(string.format(i18n.t("gapsRecent"), tostring(last.request)), "tool")
      end
    end

  elseif t == "context" then
    -- 上下文用量：底边栏的 20 格电量条
    self.panel:setContext(msg.used, msg.budget)

  elseif t == "history_result" then
    if msg.reset then
      self.panel:log(i18n.t("ctxCleared"), "info")
    elseif (msg.messages or 0) == 0 then
      self.panel:log(i18n.t("ctxEmpty"), "info")
    else
      self.panel:log(string.format(i18n.t("ctxInfo"), msg.messages or 0,
        msg.tokens or 0, msg.budgetTokens or 0), "info")
    end

  elseif t == "conversations_result" then
    self:showConversationTable(msg)

  elseif t == "conversation_result" then
    -- 结果行由桥的 say 给（已本地化）；这里只兜一句"没连上"之类
    if msg.ok == false and msg.reason == "not-found" then
      self.panel:log(i18n.t("convNotFound"), "error")
    end

  elseif t == "replay" then
    -- 关掉面板 / 重启 Aseprite 之后把上次的记录补回屏幕（替换，不是追加）
    self.panel:replayLines(msg.lines, msg.more, msg.title)

  elseif t == "open_doc" then
    self:openDocument(msg)

  elseif t == "list_workspace" then
    self:send{ type = "workspace_result", id = msg.id, root = self.workspace and self.workspace:getRoot() or "",
               files = self.workspace and self.workspace:listFiles() or {} }

  elseif t == "get_canvas" then
    self:sendCanvas(msg.id)

  -- import_image 不在这里处理：它带 binary=true，会被 ws.lua 当成"头帧"存起来，
  -- 等二进制帧到达后由 Agent:onBinary 配对调用 importImage（v0.5.9 统一了这条路）。

  else
    self.panel:log(string.format(i18n.t("unknownMessage"), tostring(t)), "error")
  end
end

-- 对话表：把桥发来的清单渲染成一张可选的表（复用命令表那套交互：敲编号/字母、点行、悬浮）
function Agent:showConversationTable(msg)
  local items = msg.items or {}
  local rows = {}
  for i, it in ipairs(items) do
    local note = string.format(i18n.t("convMeta"), tonumber(it.messages) or 0,
      panel.shortTokens(it.tokens))
    if it.active then note = note .. i18n.t("convCurrent") end
    rows[#rows + 1] = {
      id = "conv:" .. i,
      keys = "",                                  -- 对话行只认编号，不占字母键
      label = tostring(it.title or ""),
      note = note,
    }
  end
  if #items == 0 then
    self.panel:log(i18n.t("convEmpty"), "info")
    return
  end
  rows[#rows + 1] = { id = "conversation_new", keys = "n",
    label = i18n.t("convRowNew"), note = i18n.t("convRowNewNote") }
  rows[#rows + 1] = { id = "conversation_rename", keys = "r",
    label = i18n.t("convRowRename"), note = i18n.t("convRowRenameNote") }
  rows[#rows + 1] = { id = "conversation_delete", keys = "d",
    label = i18n.t("convRowDelete"), note = i18n.t("convRowDeleteNote") }

  local title = i18n.t("convTitle") .. "   --   " .. i18n.t("convFooter")
  self.panel:openTable(rows, title, "conv")
end

function Agent:onBinary(header, data)
  if header.type == "import_image" then
    self:importImage(header, data)
  else
    self.panel:log(string.format(i18n.t("unexpectedFrame"), tostring(header.type)), "error")
  end
end

----------------------------------------------------------------------
-- 内核句柄：能力包的 op 在 registry 里，执行要经 kernel:invoke 才有限时保护
--
-- 为什么是"注入 + 兜底"：agent 由 main.lua 在 loadKernel() 之后构造，但那条线
-- 目前没把 kernel 传进来。拿不到内核时这里返回 nil，名单退回 lib.ops、执行退回
-- 老路径 —— 也就是"装了内核就多一半能力，没装内核一切照旧"，绝不因为缺它而崩。
----------------------------------------------------------------------

function Agent:setKernel(kernel)
  if kernel then self._kernel = kernel end
  return self._kernel
end

function Agent:kernel()
  if self._kernel then return self._kernel end
  local k = self.cfg and self.cfg.kernel or nil
  if k then self._kernel = k; return k end
  return nil
end

-- 卸载一个能力包注册的算子（ledger 只管启停，registry 里的规格得有人撤，
-- 否则名单里会留 ghost 名字：模型看得见、一点就报 unknown op）。
-- 只撤 manifest 里声明过的；包里偷偷注册的不在账上，撤不到。
function agent.dropPackOps(kernel, packId)
  if not (kernel and kernel.registry) then return 0 end
  local ctx = kernel.packContexts and kernel.packContexts[packId]
  local declared = ctx and ctx.pack and ctx.pack.ops or nil
  local removed = 0
  for _, o in ipairs(declared or {}) do
    local name = tostring(o.name or o or "")
    if name ~= "" and kernel.registry:get("op", name) then
      kernel.registry:remove("op", name)
      removed = removed + 1
    end
  end
  return removed
end

function Agent:dropPackOps(packId)
  return agent.dropPackOps(self:kernel(), packId)
end

-- Execute the ops the model asked for. Auto-backup first.
function Agent:runOps(msg)
  local list = msg.ops or {}
  local label = msg.label or "AI edit"
  local id = msg.id

  -- 目标层：msg.layers 可以是 nil（活动层）/ "all" / "base" / {"base","detail"}
  local frame = app.activeCel and app.activeCel.frameNumber or 1
  local okCel, cels = pcall(ops.resolveCels, app.activeSprite, frame, msg.layers)
  if not okCel then
    self.panel:log(string.format(i18n.t("opsFailed"), tostring(cels)), "error")
    self:send{ type = "ops_result", id = id, ok = false, error = tostring(cels) }
    return
  end

  local okSnap, meta = pcall(versions.push, "before: " .. label, app.activeSprite)
  if okSnap then
    self.panel:log(string.format(i18n.t("autoBacked"), meta.id, meta.label), "tool")
  end

  -- 分流在 execOps 里：能力包注册的算子走 kernel:invoke（带沙箱预算），
  -- 内建算子仍走 lib.ops 的批量事务 —— 旧路径一行没变
  local ok, res = pcall(agent.execOps, list, label, cels, self:kernel())
  if ok then
    local parts = {}
    for _, r in ipairs(res.ops) do
      parts[#parts + 1] = string.format("%s %dpx", r.op, r.changed)
    end
    self.panel:log(string.format(i18n.t("applied"),
      #res.ops, res.layer or table.concat(res.layers or {}, "+"), table.concat(parts, ", ")), "tool")
    self:invalidateFrame()
    self:send{ type = "ops_result", id = id, ok = true, report = res }
  else
    self.panel:log(string.format(i18n.t("opsFailed"), tostring(res)), "error")
    self:invalidateFrame()
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

-- 作画类：新建文档 / 建图层 / 字符网格落像素。
-- new_sprite 会开出新文档，没有"改坏"的风险，不备份；
-- add_layer 和 draw_art 改的是现有文档，照例先备份。
function Agent:artOp(kind, msg)
  local id = msg.id

  if kind ~= "new_sprite" then
    local spr = app.activeSprite
    if not spr then
      self:send{ type = "art_result", id = id, ok = false, error = "no document is open" }
      return
    end
    local okSnap, meta = pcall(versions.push, "before: " .. (msg.label or kind), spr)
    if okSnap then
      self.panel:log(string.format(i18n.t("autoBacked"), meta.id, meta.label), "tool")
    end
  end

  local ok, res = pcall(function()
    if kind == "new_sprite" then
      local spr, info = artlib.newSprite(msg.width, msg.height, msg.colorMode)
      return { changed = true, op = "new_sprite", size = info.width .. "x" .. info.height,
               colorMode = info.colorMode }
    elseif kind == "add_layer" then
      local layer, info = artlib.addLayer(app.activeSprite, msg.name, msg)
      return { changed = true, op = "add_layer", layer = info.name,
               opacity = info.opacity, blendMode = info.blendMode }
    else
      local r = artlib.drawArt(app.activeSprite, msg)
      r.op = "draw_art"
      r.changed = r.painted > 0
      return r
    end
  end)

  if ok then
    -- 一个像素都没画上：**必须当失败报**。
    -- 之前这里报 ok，模型以为画好了，就一遍遍重画同一个网格直到步数耗尽 ——
    -- 用户看到的是"画 0 像素"刷屏 + "hit the 8-step tool limit"。
    -- 真正的原因（网格全是透明字符）要原样告诉模型，它才知道改哪儿。
    if kind == "draw_art" and (res.painted or 0) == 0 then
      local why = i18n.t("artNothing")
      if res.transparentChars then
        local parts = {}
        for ch, n in pairs(res.transparentChars) do
          parts[#parts + 1] = string.format("%q×%d", ch, n)
        end
        if #parts > 0 then
          why = why .. " " .. string.format(i18n.t("artNothingChars"), table.concat(parts, " "))
        end
      end
      self.panel:log(why, "error")
      self:send{ type = "art_result", id = id, ok = false, error = why, report = res }
      return
    end

    if kind == "draw_art" then
      self.panel:log(string.format(i18n.t("artDrawn"),
        res.painted, res.width, res.height, res.layer), "tool")
      if res.skippedOutOfBounds and res.skippedOutOfBounds > 0 then
        self.panel:log(string.format(i18n.t("artClipped"), res.skippedOutOfBounds), "info")
      end
    else
      self.panel:log(string.format(i18n.t("artDoc"), res.op, res.layer or res.size or ""), "tool")
    end
    self:invalidateFrame()
    self:send{ type = "art_result", id = id, ok = true, report = res }
  else
    self.panel:log(string.format(i18n.t("artFailed"), tostring(res)), "error")
    self:send{ type = "art_result", id = id, ok = false, error = tostring(res) }
  end
end

----------------------------------------------------------------------
-- 选项式提问（P7）
--
-- 桥侧的 ask_user 工具会发 {type='ask', id, question, options}，然后挂着等
-- （request 的超时是 5 分钟）。用户有三条路：终端里敲编号 / 弹窗里点按钮 /
-- 直接把窗口关了（= 取消）。三条路都必须回一帧 answer，否则桥要等到超时。
----------------------------------------------------------------------

function Agent:askUser(msg)
  -- 防重：已经有待答问题还来新的，先把旧的答成取消，别让桥挂死
  if self.pendingAskId then
    self.panel:log(i18n.t("askSuperseded"), "info")
    self:send{ type = "answer", id = self.pendingAskId, cancelled = true }
  end

  self.pendingAskId = msg.id
  self.pendingAskOptions = msg.options or {}

  local ask = { id = msg.id, question = msg.question or "", options = self.pendingAskOptions }
  self.panel:setAsk(ask)
  self.panel:_showAskDialog(ask)
end

-- index：数字 = 选了第几个；"cancel" / nil = 取消
function Agent:answerAsk(index)
  local id = self.pendingAskId
  if not id then return end

  local opts = self.pendingAskOptions or {}
  self.pendingAskId = nil
  self.pendingAskOptions = nil
  self.panel:setAsk(nil, true)
  self.panel:_closeAskDialog()

  if type(index) == "number" and opts[index] then
    self.panel:log(string.format(i18n.t("askAnswered"), tostring(opts[index])), "tool")
    self:send{ type = "answer", id = id, index = index, choice = opts[index] }
  else
    self.panel:log(i18n.t("askCancelled"), "info")
    self:send{ type = "answer", id = id, cancelled = true }
  end
end

-- 把 perfect_pixel 的结果【就地】落进当前文档：新增一个 ASCII 名图层，
-- 原图层像素一个不动，画布不够大就扩（不裁）。快照 + 工作区门禁走和 runOps 同一套纪律。
--
-- 返回 { ok=true, layer, canvas, canvasFrom, expanded, snapshot } 或 { ok=false, error }
-- info = { data, w, h, label }
function Agent:applyFixed(info)
  local spr = app.activeSprite
  if not spr then
    return { ok = false, reason = "no-document", error = "no document is open" }
  end

  local label = info.label or "apply fixed image"

  -- 工作区门禁（P10）：和 run_ops / crop / draw_art 同样的纪律。
  -- 注意必须在这里读 app.activeSprite 之后再调 —— prepareEdit 可能把用户
  -- 原文件换成工作区里的副本，spr 要在它之后重新取。
  if not self:prepareEdit("apply_fixed_image") then
    return { ok = false, error = "blocked by the workspace gate" }
  end
  spr = app.activeSprite
  if not spr then
    return { ok = false, reason = "no-document", error = "no document is open" }
  end

  -- 快照（用户拍板的要求）：label 形如 "before: apply fixed image"，
  -- 落地前先记一条，rollback 能退回应用前。
  local okSnap, snap = pcall(versions.push, "before: " .. label, spr)
  if okSnap then
    self.panel:log(string.format(i18n.t("autoBacked"), snap.id, snap.label), "tool")
  end

  local res = pixfix.applyFixedRGBA(spr, info.data, info.w, info.h, { name = info.name })
  if not res.ok then
    self.panel:log(string.format(i18n.t("fxFailed"), tostring(res.error)), "error")
    return { ok = false, error = res.error }
  end

  self.panel:log(string.format(i18n.t("fxApplied"), res.layer, res.result), "tool")
  if res.expanded then
    self.panel:log(string.format(i18n.t("fxGrew"), res.canvasFrom, res.canvas), "info")
  end
  self:invalidateFrame()

  return {
    ok = true,
    layer = res.layer,
    at = res.at,
    canvas = res.canvas,
    canvasFrom = res.canvasFrom,
    expanded = res.expanded,
    snapshot = okSnap and snap.id or nil,
  }
end

-- perfect_pixel 结果的落地入口（二进制帧：import_image 头帧 + RGBA 负载）。
--
-- 两条路，共用 applyFixed 这一份像素代码：
--   target="active"  -> 就地加图层（同一轮结束时回 import_result 给桥）
--   没有可用文档      -> 开预览文档 + 记为待应用（面板上出现「应用这个结果」）
--   target="preview" -> 上传图矫正 / 无文档兜底：开预览文档 + 记为待应用
function Agent:importImage(header, data)
  local w, h = header.width, header.height
  if not w or not h or #data ~= w * h * 4 then
    self.panel:log(string.format(i18n.t("importMismatch"),
      #data, (w or 0) * (h or 0) * 4), "error")
    self:send{ type = "import_result", id = header.id, applied = false,
               error = "size mismatch" }
    return
  end

  local target = header.target
  -- target 是桥按来源给的意图；这里再做一次事实判断：
  -- "bridge 以为是 active" 与 "现在真有文档" 是两件事（用户可能刚把文档关了）。
  if target == "active" and app.activeSprite then
    local res = self:applyFixed{
      data = data, w = w, h = h,
      label = header.label or "apply fixed image",
    }
    if res.ok then
      self:send{ type = "import_result", id = header.id, applied = true,
                 layer = res.layer, canvas = res.canvas, canvasFrom = res.canvasFrom,
                 expanded = res.expanded, pending = false }
      return
    end
    if res.reason ~= "no-document" then
      self:send{ type = "import_result", id = header.id, applied = false, error = res.error }
      return
    end
    -- 没有文档：落到下面的预览分支，同时保留待应用状态
  end

  self:setPendingApply{ data = data, w = w, h = h, label = header.label or "fixed image" }
  local ok, err = self:openPreviewDoc(data, w, h, header.note)
  if not ok then
    self:send{ type = "import_result", id = header.id, applied = false,
               pending = true, error = tostring(err) }
    return
  end
  self:send{ type = "import_result", id = header.id, applied = false, openedDoc = true,
             pending = true, noDocument = (app.activeSprite == nil) }
end

-- 开预览文档（上传图矫正 / 没有文档可贴时的兜底）。这就是改造前唯一的那条路。
function Agent:openPreviewDoc(data, w, h, note)
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
    self.panel:log(string.format(i18n.t("fxOpened"), w, h,
      note and ("  (" .. note .. ")") or ""), "ai")
    self.panel:log(i18n.t("fxPending"), "info")
    self.panel:log(i18n.t("blurry"), "info")
    return true
  end
  self.panel:log(string.format(i18n.t("importFailed"), tostring(err)), "error")
  return false, err
end

-- 待应用结果：面板据此显示「应用这个结果」，点了才落地。
function Agent:setPendingApply(info)
  self.pendingApply = info
  if self.panel then self.panel:setPendingApply(info ~= nil) end
end

function Agent:clearPendingApply()
  self:setPendingApply(nil)
end

-- 面板点了「应用这个结果」：把待应用的那份像素贴进当前活动文档。
-- 成功（含开预览文档那一步之外的任何情况）后按钮就消失。
function Agent:applyPendingFixed()
  local p = self.pendingApply
  if not p then return end
  if not app.activeSprite then
    self.panel:log(i18n.t("fxNeedDoc"), "error")
    return          -- 没有文档：待应用状态与按钮都留着，用户开好文档再点
  end

  local res = self:applyFixed{
    data = p.data, w = p.w, h = p.h,
    label = p.label or "apply fixed image",
  }
  if res.ok then
    self:clearPendingApply()
  end
end

----------------------------------------------------------------------

function Agent:destroy()
  self:cancelRetry()          -- 面板/扩展关掉时别留一个还在跑的定时器
  self._pendingSend = nil     -- 离线积压的帧也一起丢掉，别跨会话残留
  self.pendingChats = nil
  if self.conn then self.conn:close() end
  if self.settings then self.settings:destroy() end
  if self.panel then self.panel:destroy() end
end

return agent
