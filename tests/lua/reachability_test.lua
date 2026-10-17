-- tests/lua/reachability_test.lua -- 可达性不变式：画出来的每个命中区，点了都必须有可观察变化
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\\aseprite.exe" -b --script tests/lua/reachability_test.lua
--
-- 为什么要有这条：真机上出现过「一堆按钮点了没反应」——最典型的是标题栏 － 和 ×，
-- 代码里只 return 了一个字符串，没有任何动作。这种人肉很难扫干净，必须变成闸门。
--
-- 规则：
--   1. 枚举 paint 期间产生的**全部**命中区（标题栏 / 左轨 / 视图标题行动作 / 视图内部行 / composer 图标）；
--   2. 逐个点击，比较点击前后的可观测量（viewId / mode / input / 折叠 / 忙碌 / 连线 / 文档 /
--      会话行数 / agent 调用 / 重绘次数 / 视图内部状态 / noop 记录 / 面板显隐）；
--   3. 变了 → 通过；没变 → 必须在 workbench.NOOP_REASONS 白名单里，且理由非空。
--   **空函数（只 return 字符串）一律红。**

local ROOT = os.getenv("ASE_PROJ")
if ROOT == nil or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local i18n = require("lib.i18n")
i18n._resetLang()
i18n.resolve("en", "en")

local workbench = require("lib.workbench")

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
local function eq(a, b, name)
  ok(a == b, name, string.format("got %s want %s", tostring(a), tostring(b)))
end
local LEFT = (type(MouseButton) == "table" and MouseButton.LEFT) or 1

local function fakeGC(w, h)
  local g = { width = w or 900, height = h or 620, texts = {} }
  g.measureText = function(_, s) s = tostring(s or ""); return { width = (utf8.len(s) or #s) * 6, height = 12 } end
  g.fillRect = function() end
  g.fillText = function(_, s) g.texts[#g.texts + 1] = tostring(s) end
  g.drawImage = function() end
  return g
end

-- 假 agent：把所有 action/id 调用记下来（这就是"可观察变化"的一部分）
local function fakeAgent()
  local a = { calls = {}, sent = {} }
  a.panel = { log = function() end }
  function a:action(name) self.calls[#self.calls + 1] = tostring(name); return true end
  function a:send(t) self.sent[#self.sent + 1] = tostring(t); return true end
  function a:open() self.opened = (self.opened or 0) + 1 end
  function a:interrupt() self.interrupted = (self.interrupted or 0) + 1 end
  function a:connect(quiet) self.connects = (self.connects or 0) + 1; self.lastQuiet = quiet; return true end
  function a:docName() return "001.ase" end
  return a
end

local function fakeDialog()
  local d = { data = {}, widgets = {}, repaints = 0, shown = true }
  d._bounds = { x = 0, y = 0, w = 912, h = 531 }
  function d:repaint() self.repaints = self.repaints + 1 end
  function d:canvas(s) self.widgets.screen = s end
  function d:entry(s) self.widgets.input = s end
  function d:button(s) self.widgets[s.id] = s end
  function d:newrow() end
  function d:samerow() end
  function d:show() self.shown = true end
  function d:close() self.shown = false end
  function d:modify() end
  return setmetatable(d, {
    __index = function(_, k) if k == "bounds" then return d._bounds end return nil end,
    __newindex = function(t, k, v)
      if k == "bounds" then d._bounds = { x = v.x, y = v.y, w = v.width, h = v.height } else rawset(t, k, v) end
    end,
  })
end

-- 假 kernel：registry 提供 7 个视图 + 若干算子；invoke 记调用
local function fakeKernel()
  local ops = {
    { name = "contrast", label = "加强明暗对比", params = {} },
    { name = "sharpen", label = "锐化边缘", params = {} },
  }
  local commands = { { id = "snapshot", title = "Snapshot" } }
  local views = {}
  for _, id in ipairs({ "console", "canvas", "packs", "styles", "memory", "gallery", "settings" }) do
    views[#views + 1] = { id = id, title = id, icon = "·", order = #views * 10, mount = nil }
  end
  local invokes = {}
  local reg = {}
  function reg:list(kind)
    if kind == "op" then return ops end
    if kind == "command" then return commands end
    if kind == "view" then return {} end   -- 视图走 BUILTIN_VIEWS 兜底表，mount 才是真身
    return {}
  end
  function reg:get(kind, id)
    if kind == "op" then
      for _, o in ipairs(ops) do if o.name == id then return o end end
    end
    return nil
  end
  function reg:fingerprint() return "reach" end
  return {
    registry = reg,
    host = {
      active = function() return { sprite = {}, frame = 1 } end,
      resolveCels = function() return {} end,
    },
    ledger = {
      scan = function() return { { id = "sharp", name = "锐化", enabled = true } } end,
      health = function() return {} end,
      isEnabled = function() return true end,
      enable = function() end,
      disable = function() end,
    },
    invoke = function(self, kind, id, host, params)
      invokes[#invokes + 1] = tostring(id)
      return true, { changed = 42 }
    end,
    sandboxMs = 800,
    _invokes = invokes,
  }
end

local function newWB(extraOpts)
  local agent = fakeAgent()
  local kernel = fakeKernel()
  local opts = { width = 900, height = 620 }
  for k, v in pairs(extraOpts or {}) do opts[k] = v end
  local wb = workbench.new(opts)
  wb:mount(kernel, agent)
  wb:setSize(900, 620)
  local dlg = fakeDialog()
  wb:build(dlg)
  wb.shown = true
  wb:setDoc({ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 })
  wb:invalidate()
  wb:paint(fakeGC(900, 620))
  return wb, agent, kernel, dlg
end

-- 可观测量快照：任何一项变了就算"点击有反应"
local function snapshot(wb, agent, kernel, dlg)
  local v = wb.view
  local cv = wb.views and wb.views.console
  local parts = {
    "view=" .. tostring(wb.viewId),
    "mode=" .. tostring(wb.mode),
    "input=" .. tostring(wb.input),
    "inputOpen=" .. tostring(wb.inputOpen),
    "collapsed=" .. tostring(wb.collapsed),
    "busy=" .. tostring(wb.state.busy),
    "connected=" .. tostring(wb.state.connected),
    "doc=" .. tostring(wb.state.doc and wb.state.doc.name),
    "shown=" .. tostring(wb.shown),
    "focus=" .. tostring(wb.state.focus),
    "expanded=" .. tostring(wb.view and wb.view.detail and next(wb.view.detail) and "yes" or "no"),
    "lines=" .. tostring(cv and cv.count and cv:count() or -1),
    "repaints=" .. tostring(dlg and dlg.repaints or 0),
    "actions=" .. tostring(#(agent.calls or {})),
    "sent=" .. tostring(#(agent.sent or {})),
    "interrupted=" .. tostring(agent.interrupted or 0),
    "invokes=" .. tostring(#(kernel._invokes or {})),
    "viewSel=" .. tostring(v and v.sel),
    "noops=" .. tostring(wb.noops and next(wb.noops) and "yes" or "no"),
    "viewErrors=" .. tostring(wb.viewErrors and next(wb.viewErrors) and "yes" or "no"),
  }
  return table.concat(parts, "|")
end

local function rectCenter(r)
  return r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
end

local function clickAt(wb, x, y)
  local h = wb:handlers()
  h.onmousedown({ x = x, y = y, button = LEFT })
  h.onmouseup({ x = x, y = y, button = LEFT })
end

local function reasonsOk()
  local missing = {}
  for id, reason in pairs(workbench.NOOP_REASONS) do
    if type(reason) ~= "string" or reason == "" then missing[#missing + 1] = id end
  end
  return #missing == 0, table.concat(missing, ",")
end

print("== 0. 白名单本身必须带理由 ==")
do
  local okReasons, bad = reasonsOk()
  ok(okReasons, "NOOP_REASONS 每一条都有非空理由", bad)
end

----------------------------------------------------------------------
-- 1. 枚举 + 逐个点击
----------------------------------------------------------------------

local function checkAllHits(label, wb, agent, kernel, dlg, hits, excludeKinds)
  local total, dead = 0, {}
  for _, hit in ipairs(hits or {}) do
    local kind = hit.kind
    local skip = false
    for _, k in ipairs(excludeKinds or {}) do if kind == k then skip = true end end
    if not skip and hit.rect then
      total = total + 1
      -- 每次点击前把界面刷到干净状态，避免"上一次点击的副作用"冒充这一次的反应
      wb:invalidate()
      wb:paint(fakeGC(900, 620))
      local before = snapshot(wb, agent, kernel, dlg)
      local x, y = rectCenter(hit.rect)
      clickAt(wb, x, y)
      local after = snapshot(wb, agent, kernel, dlg)
      if before == after then
        local id = tostring(hit.id or kind)
        -- 视图内动作/壳动作的 noop 白名单键有两种前缀
        local whitelisted = workbench.NOOP_REASONS["action." .. id]
          or workbench.NOOP_REASONS["composer." .. id]
          or workbench.NOOP_REASONS[id]
          or (wb.noops and wb.noops["action." .. id])
          or (wb.noops and wb.noops["composer." .. id])
          or (wb.noops and wb.noops[id])
        if not whitelisted then
          dead[#dead + 1] = label .. ":" .. id .. "@" .. tostring(hit.rect.x) .. "," .. tostring(hit.rect.y)
        end
      end
    end
  end
  ok(#dead == 0, label .. "：全部命中区点击后都有可观察变化（" .. total .. " 个）", table.concat(dead, " / "))
  return total
end

print("== 1. 标题栏 / 左轨 / composer / 视图标题行动作 ==")
do
  local wb, agent, kernel, dlg = newWB()
  local total = 0

  -- 标题栏 4 个按钮
  total = total + checkAllHits("titlebar", wb, agent, kernel, dlg, wb.titleHits)

  -- 左轨 7 个视图 + ⊕
  local wb2, agent2, kernel2, dlg2 = newWB()
  total = total + checkAllHits("rail", wb2, agent2, kernel2, dlg2, wb2.railHits)

  -- composer 三个图标（⏎ / 📎 / ⏹）
  local wb3, agent3, kernel3, dlg3 = newWB()
  wb3:setInput("hi")
  wb3:openInput()
  wb3:invalidate()
  wb3:paint(fakeGC(900, 620))
  total = total + checkAllHits("composer", wb3, agent3, kernel3, dlg3, wb3.composerHits)

  -- 每个视图的标题行动作
  for _, viewId in ipairs({ "console", "canvas", "packs", "styles", "memory", "gallery", "settings" }) do
    local wbV, agentV, kernelV, dlgV = newWB()
    wbV:setView(viewId)
    wbV:invalidate()
    wbV:paint(fakeGC(900, 620))
    total = total + checkAllHits("action@" .. viewId, wbV, agentV, kernelV, dlgV, wbV.actionHits)
  end

  ok(total >= 15, "枚举到足量命中区（不是空转）", total)
end

print("== 2. 每个视图内部的行 / 按钮也要有反应 ==")
do
  local total = 0
  for _, viewId in ipairs({ "console", "canvas", "packs", "styles", "memory", "gallery", "settings" }) do
    local wbV, agentV, kernelV, dlgV = newWB()
    wbV:setView(viewId)
    wbV:invalidate()
    wbV:paint(fakeGC(900, 620))
    local v = wbV.view
    total = total + checkAllHits("view@" .. viewId, wbV, agentV, kernelV, dlgV, v and v.hits or {})
  end
  ok(total >= 10, "视图内部也枚举到足量命中区", total)
end

print("== 3. 断连态的重试按钮：真的调 agent:connect（不是只改本地标志）==")
do
  local wb, agent, kernel, dlg = newWB()
  wb:setConnected(false, { reason = "bridge refused", cmd = "node x.mjs" })
  wb:invalidate()
  wb:paint(fakeGC(900, 620))
  ok(wb.retryHit ~= nil, "断连态画出了重试按钮")
  if wb.retryHit then
    local x, y = rectCenter(wb.retryHit)
    local connectsBefore = agent.connects or 0
    clickAt(wb, x, y)
    eq((agent.connects or 0) - connectsBefore, 1, "点重试调用了 agent:connect() 一次（真的重连）")
    ok(wb.state.busy == true, "等待结果时 state.busy=true")
    ok(tostring(wb.state.status):find("reconnect", 1, true) ~= nil
       or tostring(wb.state.status):find("重连", 1, true) ~= nil,
       "状态显示「正在重连…」", wb.state.status)

    -- 真实回调（ws.onOpen → panel:setStatus(...,'ok')）到达后，断连态要自己收掉
    wb:setStatus("connected", "ok")
    eq(wb.state.connected, true, "真实回调把 connected 改回 true")
    wb:setBusy(false)
    wb:invalidate()
    wb:paint(fakeGC(900, 620))
    eq(wb.retryHit, nil, "连上后红条与重试按钮消失")
  end

  -- 没有 connect 入口时不许假装成功
  local wb2, agent2, kernel2, dlg2 = newWB({})
  agent2.connect = nil
  wb2:setConnected(false, { reason = "x", cmd = "y" })
  wb2:invalidate(); wb2:paint(fakeGC(900, 620))
  if wb2.retryHit then
    local x, y = rectCenter(wb2.retryHit)
    clickAt(wb2, x, y)
    ok(wb2.state.connected == false, "没有 connect 入口时不假装连上")
  end
end

print("== 4. 最小化 / 关闭的具体语义 ==")
do
  local wb, agent, kernel, dlg = newWB()
  -- － 必须真的切到小窗形态，再点回来
  local minHit = nil
  for _, hit in ipairs(wb.titleHits or {}) do if hit.id == "min" then minHit = hit end end
  ok(minHit ~= nil, "标题栏有 － 命中框")
  if minHit then
    local x, y = rectCenter(minHit.rect)
    eq(wb.mode, "panel", "点之前是面板形态")
    clickAt(wb, x, y)
    eq(wb.mode, "small", "点 － 切到小窗形态")
    wb:invalidate(); wb:paint(fakeGC(360, 56))
    clickAt(wb, x, y)
    eq(wb.mode, "panel", "再点 － 回到面板形态")
  end
  -- × 必须关面板（shown=false）而不是什么都不做
  local closeHit = nil
  for _, hit in ipairs(wb.titleHits or {}) do if hit.id == "close" then closeHit = hit end end
  ok(closeHit ~= nil, "标题栏有 × 命中框")
  if closeHit then
    local x, y = rectCenter(closeHit.rect)
    eq(wb.shown, true, "点之前面板是开着的")
    clickAt(wb, x, y)
    eq(wb.shown, false, "点 × 关掉面板（不是关 Aseprite）")
  end
end

print("== 5. 打开文件：composer 的 📎 走 agent 的选图通路 ==")
do
  local wb, agent, kernel, dlg = newWB()
  wb:invalidate(); wb:paint(fakeGC(900, 620))
  local attach = nil
  for _, hit in ipairs(wb.composerHits or {}) do if hit.id == "attach" then attach = hit end end
  ok(attach ~= nil, "composer 有 📎 命中框")
  if attach then
    local x, y = rectCenter(attach.rect)
    clickAt(wb, x, y)
    local found = false
    for _, c in ipairs(agent.calls) do if c == "upload" then found = true end end
    ok(found, "点 📎 调用了 agent:action(upload)（原生选图通道）", table.concat(agent.calls, ","))
  end
end

print("== 6. 原生模态窗（📎 选图器）关掉后工作台要能自己回来（_afterModal）==")
do
  local wb, agent, kernel, dlg = newWB()
  -- 模拟宿主行为：打开原生模态窗的瞬间把我们的 dialog 收掉
  local realAction = agent.action
  agent.action = function(self, name)
    realAction(self, name)
    if name == "upload" then dlg.shown = false; wb.shown = false end
    return true
  end
  wb:invalidate(); wb:paint(fakeGC(900, 620))
  local attach = nil
  for _, hit in ipairs(wb.composerHits or {}) do if hit.id == "attach" then attach = hit end end
  ok(attach ~= nil, "composer 有 📎 命中框")
  if attach then
    clickAt(wb, rectCenter(attach.rect))
    eq(wb.shown, true, "选图器关掉之后，工作台自己重新显示了")
    ok((wb.modalRecovered or 0) >= 1, "记下了 modalRecovered 次数", wb.modalRecovered)
  end
end

print("== 7. × 真的关窗，且能再打开 ==")
do
  -- 注入两代假 Dialog：用来验证"关掉后 show 会重建一个新的"
  local dialogs = {}
  local wb, agent, kernel, dlg = newWB({
    newDialog = function()
      local d = fakeDialog()
      dialogs[#dialogs + 1] = d
      return d
    end,
  })
  wb:show()
  eq(#dialogs, 1, "第一次 show 建了 1 个 Dialog")
  dlg = wb.dlg
  local closeHit = nil
  for _, hit in ipairs(wb.titleHits or {}) do if hit.id == "close" then closeHit = hit end end
  -- 假 Dialog 记录 close/show 次数（真机上这两件事必须都发生）
  local closes, shows = 0, 0
  local realClose, realShow = dlg.close, dlg.show
  dlg.close = function(self) closes = closes + 1; return realClose(self) end
  dlg.show = function(self) shows = shows + 1; return realShow(self) end

  clickAt(wb, rectCenter(closeHit.rect))
  eq(wb.shown, false, "点 × 后 shown=false")
  eq(closes, 1, "点 × 真的调用了 dlg:close()（不是只改状态）")
  ok(wb.dlgClosed == true, "记下 dlgClosed，下次 show 会重建")
  ok(wb.lastCloseError == nil, "关闭没有静默失败", wb.lastCloseError)

  -- 再打开：dlgClosed 消耗掉，重新 show（会建一个新的 Dialog）
  wb:show()
  eq(wb.shown, true, "能再次打开（shown=true）")
  eq(wb.dlgClosed, false, "重建标记已消费")
  ok(wb.dlg ~= nil, "有对话框实例")
  eq(#dialogs, 2, "重建走的是新 Dialog（不是复用已关闭的那个）", #dialogs)
end

print("== 8. 小窗形态必须有内容且能打字（D4：状态行 + 最后一行输出 + 可输入）==")
do
  local wb, agent, kernel, dlg = newWB()
  wb:log("last line output", "info")
  wb:setStatus("connected", "ok")
  wb:setMode("small")
  wb:setSize(360, 56)
  local gcSmall = fakeGC(360, 56)
  wb:invalidate()
  wb:paint(gcSmall)

  local L = wb:layout()
  ok(L.small == true, "小窗布局标记")
  ok(L.main.h > 0, "有小窗状态行区域", L.main.h)
  ok(L.composer.h > 0, "小窗里 composer 高度 > 0（否则打不了字）", L.composer.h)
  eq(L.main.h + L.composer.h, 56, "状态行 + composer 正好铺满小窗")

  -- 画面真的画出了东西：两个区都有绘制调用
  local mainCalls, compCalls = 0, 0
  for _, c in ipairs(wb.kit.calls) do
    if c.region == "main" then mainCalls = mainCalls + 1 end
    if c.region == "composer" then compCalls = compCalls + 1 end
  end
  ok(mainCalls > 0, "小窗状态行真的画了东西", mainCalls)
  ok(compCalls > 0, "小窗 composer 真的画了东西（不是全黑）", compCalls)

  -- 小窗里输入行常驻，能直接打字（entry 有焦点时由宿主把字符送进 entry）
  ok(wb.inputOpen, "小窗里输入行常驻（不必先点一下）")
  wb:setInput("h")
  eq(wb:getInput(), "h", "小窗里输入可用")
  ok(L.composer.h > 0, "小窗 composer 可见", L.composer.h)

  -- 再点 － 回到面板形态，内容区恢复
  wb:setMode("panel")
  wb:setSize(900, 620)
  wb:invalidate()
  wb:paint(fakeGC(900, 620))
  local L2 = wb:layout()
  ok(L2.rail ~= nil and L2.rail.w == 56, "回到面板形态有左轨")
  ok(L2.composer.h == 40, "回到面板形态 composer 是 40")
end

print("== 9. 绘制过程中改状态，收尾要补一帧（真机自点击踩到的）==")
do
  local wb, agent, kernel, dlg = newWB()
  local before = dlg.repaints
  local orig = wb._paint
  local first = true
  function wb:_paint(gc)
    if first then
      first = false
      -- 模拟"在自己的绘制回调里改状态"（真机的自点击就是这样）
      self:setMode("small")
    end
    return orig(self, gc)
  end
  wb:invalidate()
  wb:paint(fakeGC(360, 56))
  ok(dlg.repaints > before, "帧内失效会在收尾时再请一帧", dlg.repaints - before)
end

print("== 10. 设置页：点行进入画布内编辑态，不再弹原生窗 ==")
do
  local wb, agent, kernel, dlg = newWB()
  agent.config = { baseUrl = "https://api.openai.com/v1", model = "gpt-4o", apiKeySet = true, apiKeyHint = "abcd",
                   temperature = 0.2, maxSteps = 24, contextTokens = 16000, thinking = "auto",
                   timeoutMs = 180000, maxTurnMs = 600000 }
  wb:setView("settings")
  wb:invalidate(); wb:paint(fakeGC(900, 620))

  local rows = wb.view:fields()
  eq(#rows, 10, "设置页一共 10 个字段（一个不少）")
  local keys = {}
  for _, f in ipairs(rows) do keys[#keys + 1] = f.key end
  eq(table.concat(keys, ","),
     "baseUrl,model,apiKey,language,temperature,maxSteps,contextTokens,thinking,timeoutSec,maxTurnSec",
     "字段顺序与清单一致")

  local modelHit = nil
  for _, hit in ipairs(wb.view.hits or {}) do if hit.id == "model" then modelHit = hit end end
  ok(modelHit ~= nil, "模型行有命中区")
  local callsBefore = #agent.calls
  clickAt(wb, rectCenter(modelHit.rect))
  ok(wb.fieldEdit ~= nil, "点行进入了字段编辑态")
  -- 本测试把语言钉在 en，所以标签是英文
  eq(wb.fieldEdit and wb.fieldEdit.label, "Model", "编辑态显示字段名")
  eq(wb:getInput(), "gpt-4o", "当前值已预填")
  eq(wb.inputOpen, true, "原生输入行浮出来（中文/输入都需要它）")
  eq(#agent.calls, callsBefore, "**没有**调用 agent:action(settings)（不再弹旧原生窗）")

  -- Enter：写回 set_config
  wb:setInput("gpt-4.1")
  wb:submit()
  local lastSend = agent.sent and nil
  local payload = nil
  for _, s in ipairs(agent.sentPayloads or {}) do payload = s end
  ok(wb.fieldEdit == nil, "保存成功后退出编辑态")
  eq(wb.inputOpen, true, "保存后输入行仍常驻")
end

print("== 11. 设置字段：Enter 落盘 / Esc 不落盘 / 非法值保留编辑态 ==")
do
  local wb, agent, kernel, dlg = newWB()
  local sends = {}
  function agent:send(t) self.sent[#self.sent + 1] = tostring(t); sends[#sends + 1] = t; return true end
  agent.config = { model = "gpt-4o", temperature = 0.2, maxSteps = 24, contextTokens = 16000,
                   thinking = "auto", timeoutMs = 180000, maxTurnMs = 600000, baseUrl = "https://x/v1",
                   apiKeySet = true, apiKeyHint = "abcd" }
  wb:setView("settings")
  wb:invalidate(); wb:paint(fakeGC(900, 620))

  local function hitOf(key)
    for _, hit in ipairs(wb.view.hits or {}) do if hit.id == key then return hit end end
    return nil
  end

  -- Model：改完回车
  clickAt(wb, rectCenter(hitOf("model").rect))
  wb:setInput("gpt-4.1")
  wb:submit()
  eq(#sends, 1, "Enter 后发出 1 条 set_config")
  eq(sends[1] and sends[1].type, "set_config", "帧类型是 set_config")
  eq(sends[1] and sends[1].llm and sends[1].llm.model, "gpt-4.1", "llm.model 是新值")
  eq(wb.view.overlay.model, "gpt-4.1", "本地立刻反映新值（不等下一帧 status）")

  -- Temperature：非法值 → 报错并保留编辑态，不落盘
  wb:setView("settings"); wb:invalidate(); wb:paint(fakeGC(900, 620))
  clickAt(wb, rectCenter(hitOf("temperature").rect))
  wb:setInput("9.9")
  local loaded = wb:getInput()
  wb:submit()
  eq(#sends, 1, "非法值不落盘")
  ok(wb.fieldEdit ~= nil, "非法值保留编辑态（让用户改完再回车）")
  eq(wb:getInput(), loaded, "非法值留在输入框里")

  -- Esc：取消，不落盘
  wb:setInput("0.5")
  local lvl = wb:escape()
  eq(lvl, "field", "Esc 优先取消字段编辑")
  eq(#sends, 1, "Esc 不落盘")
  eq(wb.fieldEdit, nil, "Esc 后退出编辑态")
  eq(wb.view.overlay.temperature, nil, "Esc 后本地值也没变")

  -- 超时字段：秒 → 毫秒
  wb:setView("settings"); wb:invalidate(); wb:paint(fakeGC(900, 620))
  clickAt(wb, rectCenter(hitOf("timeoutSec").rect))
  eq(wb:getInput(), "180", "超时字段预填秒数")
  wb:setInput("240")
  wb:submit()
  eq(sends[#sends].llm.timeoutMs, 240000, "单次超时按秒输入、按毫秒落盘")

  -- 密钥：留空 = 保持不变（不发 apiKey）
  wb:setView("settings"); wb:invalidate(); wb:paint(fakeGC(900, 620))
  clickAt(wb, rectCenter(hitOf("apiKey").rect))
  eq(wb:getInput(), "", "密钥不预填（不回显真 key）")
  local n = #sends
  wb:submit()
  eq(#sends, n, "密钥留空不发 set_config")
  eq(wb.fieldEdit, nil, "密钥留空也算完成（退出编辑态）")

  -- 思考强度：枚举校验
  wb:setView("settings"); wb:invalidate(); wb:paint(fakeGC(900, 620))
  clickAt(wb, rectCenter(hitOf("thinking").rect))
  wb:setInput("turbo")
  wb:submit()
  ok(wb.fieldEdit ~= nil, "非枚举值被拒（保留编辑态）")
  wb:setInput("high")
  wb:submit()
  eq(sends[#sends].llm.thinking, "high", "合法枚举值落盘")
end

print("== 12. 等待授权：3s 内没有结果就把红条改成「去点 Allow」 ==")
do
  local wb, agent, kernel, dlg = newWB()
  wb:setConnected(false, { reason = "bridge refused", cmd = "node x.mjs" })
  wb:invalidate(); wb:paint(fakeGC(900, 620))
  local before = wb:disconnectReason()
  ok(tostring(before):find("bridge refused", 1, true) ~= nil, "刚开始显示的是已知原因", before)

  -- 模拟"发起连接已经过去 5 秒，既没 onOpen 也没 onError"
  wb:noteConnectAttempt()
  wb.state.connectStartedAt = os.clock() - 5
  local reason, tone = wb:disconnectReason()
  ok(tostring(reason):find("Allow to Open Connections", 1, true) ~= nil,
     "超时后文案提示去点 Allow to Open Connections", reason)
  ok(tostring(reason):find("Security", 1, true) ~= nil, "文案点明是 Security 窗口")
  eq(tone, "warn", "等待授权用 warn 色（不是纯错误红）")

  -- 画出来：红条上真的出现这段字
  wb:invalidate(); local gc = fakeGC(900, 620); wb:paint(gc)
  local drewAuth = false
  for _, txt in ipairs(gc.texts) do
    if txt:find("Allow to Open Connections", 1, true) then drewAuth = true end
  end
  ok(drewAuth, "红条上真的画出了授权提示")

  -- 有结果之后文案回退，不再显示"在等授权"
  wb:setStatus("connected", "ok")
  eq(wb.state.connectStartedAt, nil, "连上后清掉等待计时")
  eq(wb:waitingForAuth(), false, "连上后不再是等待授权态")

  -- 3 秒内不该误报
  local wb2 = newWB()
  wb2:setConnected(false, { reason = "x", cmd = "y" })
  wb2:noteConnectAttempt()
  eq(wb2:waitingForAuth(), false, "刚发起连接（<3s）不显示授权提示")
end

print("== 13. 设置页：必填标记 / 未配置提示 / 顶部引导 ==")
do
  local wb, agent, kernel, dlg = newWB()
  agent.cfg = { port = 8777 }
  agent.config = { }        -- 什么都没配
  wb:setView("settings")
  wb:invalidate()
  local gc = fakeGC(900, 620)
  wb:paint(gc)

  local introDrawn, starDrawn, unsetDrawn = false, false, false
  for _, txt in ipairs(gc.texts) do
    if txt:find("127.0.0.1:8777", 1, true) then introDrawn = true end
    if txt:find(" *", 1, true) then starDrawn = true end
    if txt == "not set" or txt == "未设置" then unsetDrawn = true end
  end
  ok(introDrawn, "顶部有本地桥地址与三项必填的引导")
  ok(starDrawn, "必填字段带 * 标记")
  ok(unsetDrawn, "未配置显示「未设置」/「not set」")

  local rows = wb.view:fields()
  local required, missing = 0, 0
  for _, f in ipairs(rows) do
    if f.required then required = required + 1 end
    if f.missing then missing = missing + 1 end
  end
  eq(required, 3, "端点/模型/密钥三项标为必填")
  ok(missing >= 3, "三项都没配时都标成 missing", missing)

  -- 配好之后：密钥显示掩码而不是"未设置"
  agent.config = { baseUrl = "https://api.openai.com/v1", model = "gpt-4o", apiKeySet = true, apiKeyHint = "9f2c" }
  wb:invalidate()
  local gc2 = fakeGC(900, 620)
  wb:paint(gc2)
  local masked = false
  for _, txt in ipairs(gc2.texts) do if txt:find("***9f2c", 1, true) then masked = true end end
  ok(masked, "已配置时密钥显示掩码 ***9f2c")
end

print("== 14. 未连接桥时保存：直接说「未连接桥，无法保存」 ==")
do
  local wb, agent, kernel, dlg = newWB()
  local sends = {}
  function agent:send(t) sends[#sends + 1] = t; return true end
  agent.config = { model = "gpt-4o" }
  wb:setView("settings")
  wb:setConnected(false, { reason = "bridge refused", cmd = "node x.mjs" })
  wb:invalidate(); wb:paint(fakeGC(900, 620))

  local modelHit = nil
  for _, hit in ipairs(wb.view.hits or {}) do if hit.id == "model" then modelHit = hit end end
  ok(modelHit ~= nil, "设置页有模型行")
  if modelHit then
    clickAt(wb, rectCenter(modelHit.rect))
    ok(wb.fieldEdit ~= nil, "进入编辑态")
    wb:setInput("gpt-4.1")
    local cv = wb.views.console
    local linesBefore = cv:count()
    wb:submit()
    eq(#sends, 0, "未连接时不发 set_config（不静默失败）")
    ok(cv:count() > linesBefore, "会话里出现一行说明")
    local lastText = ""
    for i = cv:count(), 1, -1 do
      if cv.lines[i] then lastText = tostring(cv.lines[i].text); break end
    end
    ok(tostring(lastText):find("未连接桥", 1, true) ~= nil or tostring(lastText):find("not connected", 1, true) ~= nil,
       "错误文案明确说「未连接桥，无法保存」", lastText)
    ok(wb.fieldEdit ~= nil, "失败保留编辑态，值不丢")
  end
end

print("== 15. 待答提问：回复必须走 answer，不能发 chat（静默死锁）==")
do
  local wb, agent, kernel, dlg = newWB()
  local answers, chats = {}, {}
  -- 照真实 agent 的契约：answerAsk 会清掉 pendingAskId/pendingAskOptions
  function agent:answerAsk(index)
    answers[#answers + 1] = index
    self.pendingAskId = nil
    self.pendingAskOptions = nil
    return true
  end
  function agent:sendChat(text) chats[#chats + 1] = tostring(text); return true end
  function agent:sendChatNow(text) chats[#chats + 1] = tostring(text); return true end

  -- 模拟桥发来 ask_user
  agent.pendingAskId = "ask-1"
  agent.pendingAskOptions = { "64x64", "128x128", "256x256" }
  ok(wb:hasPendingAsk(), "有待答提问时 hasPendingAsk() 为真")

  -- 输入编号 → answerAsk(n)，不发 chat
  wb:setInput("2")
  wb:submit()
  eq(answers[1], 2, "输入 2 → answerAsk(2)")
  eq(#chats, 0, "答题时**不发 chat**（桥在等 answer，chat 会被丢掉）")

  -- 取消词 → answerAsk(nil)
  agent.pendingAskId = "ask-2"
  wb:setInput("算了")
  wb:submit()
  eq(answers[2], nil, "取消词 → answerAsk(nil) 走 cancelled 分支")
  eq(#chats, 0, "取消也不发 chat")

  -- 自由文本 → 先取消提问，再发 chat
  agent.pendingAskId = "ask-3"
  wb:setInput("我要 512x512")
  wb:submit()
  eq(answers[3], nil, "自由文本先取消这次提问")
  eq(chats[1], "我要 512x512", "然后再按普通消息发出")
  eq(agent.pendingAskId, nil, "取消后 pendingAskId 清空")

  -- Esc 也能取消提问
  agent.pendingAskId = "ask-4"
  eq(wb:escape(), "ask", "Esc 优先取消待答提问")
  ok(wb.state.ask == nil, "取消后 workbench 的 ask 也清空")

  -- agent 清掉 pendingAsk 之后，不再走答题分支
  local chatsBefore = #chats
  wb:setInput("正常消息")
  wb:submit()
  eq(#chats, chatsBefore + 1, "没有待答提问时照常发 chat")
end

print("== 16. 形态切换有视觉反馈（真机验证/误触时能确认）==")
do
  local wb, agent, kernel, dlg = newWB()
  wb:setMode("panel")
  wb:setMode("bar_side")
  local flash = wb:modeFlashActive()
  ok(flash ~= nil, "切形态后进入闪现态")
  ok(tostring(flash):find("侧边栏", 1, true) ~= nil or tostring(flash):find("side", 1, true) ~= nil,
     "闪现内容是该形态名", tostring(flash))
  wb:invalidate()
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  local drew = false
  for _, txt in ipairs(gc.texts) do
    if txt:find("侧边栏", 1, true) or txt:find("side bar", 1, true) then drew = true end
  end
  ok(drew, "标题栏上真的画出了形态名")

  -- 过期后自动消失
  wb.state.modeFlash.untilT = os.clock() - 1
  eq(wb:modeFlashActive(), nil, "超过 1.5s 后闪现自动失效")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))