-- lib/workbench.lua -- 三区工作台壳（titlebar / 左轨 / 主视图 / 右上下文 / composer）
--
-- 壳只认 registry 与 theme，**不认具体视图**：视图从 registry 的 view 规格来，
-- 壳负责把五块区域切成 rect、管好各自的脏标记、把键盘事件按焦点路由下去。
--
-- 五个脏区各自独立失效（ui §7）：整屏重绘没有入口 —— 只有窗口尺寸变化会一次性
-- 全标脏，那是唯一合法的情况。滚动只脏 main，输入回显只脏 composer。

local kitMod = require("kernel.kit")
local themeMod = require("lib.theme")
local util = require("lib.util")
local i18n = require("lib.i18n")

local workbench = {}
local Workbench = {}
workbench.Workbench = Workbench

workbench.MODES = { "panel", "bar_bottom", "bar_side", "small" }

-- 内置视图：registry 里没有 view 规格时的兜底名单（pack 可以覆盖同 id）。
-- order 决定左轨顺序，也决定 Alt+1..6 的编号。
local BUILTIN_VIEWS = {
  { id = "console",  module = "lib.views.console",  icon = "▤", order = 10, zh = "会话",  en = "CONSOLE" },
  { id = "canvas",   module = "lib.views.canvas",   icon = "◎", order = 20, zh = "画布",  en = "CANVAS" },
  { id = "styles",   module = "lib.views.styles",   icon = "◈", order = 30, zh = "风格",  en = "STYLES" },
  { id = "memory",   module = "lib.views.memory",   icon = "✦", order = 40, zh = "记忆",  en = "MEMORY" },
  { id = "packs",    module = "lib.views.packs",    icon = "⬡", order = 50, zh = "扩展",  en = "PACKS" },
  { id = "gallery",  module = "lib.views.gallery",  icon = "▦", order = 60, zh = "画廊",  en = "GALLERY" },
  { id = "settings", module = "lib.views.settings", icon = "⚙", order = 70, zh = "设置",  en = "SETTINGS" },
}
workbench.BUILTIN_VIEWS = BUILTIN_VIEWS

-- 视图模块在**本模块加载时**（= init() 作用域内）一次性 require 完。
--
-- 为什么不能懒加载：STATUS 约束 7 —— require 只在 init() 里可用。而视图是"打开面板"
-- 的命令回调里才挂载的，那时全局 require 已经是 nil。懒 require 的结果是每个视图都拿不到
-- 实现，core 包的 view.mount 只能退回占位视图 —— 界面上就是「这个视图挂载失败：mount failed」
-- （真机实测；tests/lua/integration_wiring_test.lua 能在无头下复现并钉住）。
local MODULES = {}
for _, b in ipairs(BUILTIN_VIEWS) do
  local ok, mod = pcall(require, b.module)
  if ok and type(mod) == "table" then MODULES[b.id] = mod end
end
workbench.modules = MODULES

-- 解析内置视图模块：先吃上面预加载的表；只有在 require 还可用时（单测/脚本）才补加载
local function builtinModule(id)
  local mod = MODULES[id]
  if mod then return mod end
  if type(require) ~= "function" then return nil end
  for _, b in ipairs(BUILTIN_VIEWS) do
    if b.id == id then
      local ok, res = pcall(require, b.module)
      if ok and type(res) == "table" then
        MODULES[id] = res
        return res
      end
    end
  end
  return nil
end
workbench.builtinModule = builtinModule

-- 视图实现表：id -> function(ctx) -> view。
-- 这是**渲染实现**的唯一出口：main.lua 把它注给 core 包，core 的 view.mount 只做转交，
-- 注册归属仍在 registry（registry 是唯一视图权威，见与 T1 的裁决）。
workbench.renderers = {}
for _, b in ipairs(BUILTIN_VIEWS) do
  workbench.renderers[b.id] = function(ctx)
    local mod = builtinModule(b.id)
    if not mod then return nil end
    if type(mod.mount) == "function" then return mod.mount(ctx) end
    if type(mod.new) == "function" then return mod.new(ctx) end
    return nil
  end
end

-- 断连时给用户一条能直接复制的起桥命令（ui §5）
workbench.BRIDGE_CMD = "cd bridge; node src/server.mjs"

-- 壳自带的命令：不依赖任何能力包，Ctrl+K 里永远找得到。
-- 第一条是**逃生口**：新 UI 出任何问题，用户一个命令就回到证明可用的旧终端面板。
workbench.BUILTIN_COMMANDS = {
  {
    id = "ui.legacy_panel",
    title = "使用旧面板 / legacy panel",
    keys = "legacy",
    hint = "关掉工作台，回到旧的终端面板",
    run = function(ctx, arg)
      local wb = ctx and ctx.workbench
      if wb and type(wb.useLegacyPanel) == "function" then return wb:useLegacyPanel() end
      return false
    end,
  },
}

local function nowDefault() return os.clock() end

-- 只对纯 ASCII 改大小写。
-- 为什么：string.upper/lower 是**字节级**的，对 UTF-8 会把多字节序列改坏（"会话"
-- 之类），而 gc:fillText 拿到非法 UTF-8 会直接把宿主带崩 —— 实测 0xC000001D，
-- 不是抛错、是整个进程消失。这类字符串只能原样画。
local function pureAscii(s)
  s = tostring(s or "")
  return s:find("[\128-\255]") == nil
end
local function upperText(s)
  s = tostring(s or "")
  return pureAscii(s) and s:upper() or s
end
local function lowerText(s)
  s = tostring(s or "")
  return pureAscii(s) and s:lower() or s
end
workbench.upperText = upperText
workbench.lowerText = lowerText

----------------------------------------------------------------------

function workbench.new(opts)
  opts = opts or {}
  local th = opts.theme or themeMod.new({ name = opts.themeName or "dark", sprite = opts.sprite })
  local self = setmetatable({
    opts = opts,
    th = th,
    now = opts.now or nowDefault,
    mode = opts.mode or "panel",
    w = opts.width or th.metrics.defaultW,
    h = opts.height or th.metrics.defaultH,
    ctxCollapsed = opts.ctxCollapsed or false,
    viewId = opts.viewId or "console",
    kernel = nil,
    agent = nil,
    host = nil,
    registry = nil,
    kit = nil,
    views = {},          -- id -> 已 mount 的视图实例
    specs = {},          -- 排好序的 view 规格
    state = {
      connected = true,
      status = "",
      busy = false,
      focus = "composer",
      hover = nil,
      session = nil,
      doc = nil,
      todos = 0,
      steps = 0,
      elapsed = 0,
    },
    input = "",
    -- 字段编辑态：设置页点一行就进这里，composer 变单行编辑器（不再弹旧面板的原生设置窗）
    fieldEdit = nil,
    -- 原生输入行（entry + 磁吸按钮）默认收起来：用户明确说过那条白横条是控制台时代遗留。
    -- 但 entry 不能删 —— Aseprite 里只有 ui::Entry 开 IME，自绘 canvas 收不到中文。
    inputOpen = false,
    completionOpen = false,
    paletteOpen = false,
    paletteQuery = "",
    paletteSel = 1,
    interruptArmed = nil,
    dirtyNote = {},
    shown = false,
  }, { __index = Workbench })
  self:invalidate()

  -- main.lua 的接法是 workbench.new{ kernel=, agent=, registry=, host=, bus= }，
  -- 所以 new 之后再 statically 挂一次；也可以显式 wb:mount(kernel, agent)。
  if opts.kernel or opts.registry or opts.host then
    self:mount(opts.kernel or { registry = opts.registry, host = opts.host, bus = opts.bus }, opts.agent)
  end
  return self
end

----------------------------------------------------------------------
-- 挂载
----------------------------------------------------------------------

-- kernel = { bus=, registry=, host=, ledger= }, agent = lib/agent 的实例（可为 nil）
-- 签名以 arch §3.2 的 view 规格为准：mount(ctx) -> view，ctx 里有 kit / host / invalidate。
function Workbench:mount(kernel, agent)
  self.kernel = kernel
  self.agent = agent
  self.registry = kernel and kernel.registry or nil
  self.host = kernel and kernel.host or nil
  if not self.kit then self.kit = kitMod.new(nil, self.th) end
  self.ctx = {
    kernel = kernel,
    renderers = workbench.renderers,
    registry = self.registry,
    host = self.host,
    agent = agent,
    ledger = kernel and kernel.ledger or nil,
    bus = kernel and kernel.bus or nil,
    kit = self.kit,
    theme = self.th,
    workbench = self,
    i18n = i18n,
    invalidate = function(region) self:invalidate(region) end,
    log = function(text, kind, meta) self:log(text, kind, meta) end,
    meta = { manifest = {}, id = "builtin" },
  }
  self:_loadSpecs()
  self:_mountCurrent()
  self:invalidate()
  return self
end

function Workbench:_loadSpecs()
  local specs = {}
  local fromReg = {}
  if self.registry and self.registry.list then
    local ok, list = pcall(function() return self.registry:list("view") end)
    if ok and type(list) == "table" then fromReg = list end
  end
  local seen = {}
  for _, spec in ipairs(fromReg) do
    if spec and spec.id then
      specs[#specs + 1] = {
        id = spec.id,
        title = spec.title or spec.id,
        icon = spec.icon or "·",
        order = spec.order or 100,
        mount = spec.mount,
        refresh = spec.refresh,
        unmount = spec.unmount,
        from = "registry",
      }
      seen[spec.id] = true
    end
  end
  for _, b in ipairs(BUILTIN_VIEWS) do
    if not seen[b.id] then
      local mod = builtinModule(b.id)
      if mod then
        specs[#specs + 1] = {
          id = b.id, title = i18n.isZh() and b.zh or b.en,
          icon = b.icon, order = b.order, module = mod, from = "builtin",
        }
      end
    end
  end
  table.sort(specs, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return tostring(a.id) < tostring(b.id)
  end)
  self.specs = specs
  if not self:_specOf(self.viewId) then
    self.viewId = specs[1] and specs[1].id or "console"
  end
end

function Workbench:_specOf(id)
  for _, s in ipairs(self.specs or {}) do
    if s.id == id then return s end
  end
  return nil
end

-- 包代码限时：视图的 mount / render 都可能由能力包提供，一个死循环的 render
-- 会把 Aseprite 的 UI 线程带走 —— 那等于"模型能加视图"这件事有毒。
-- 只包调用，不改任何视图实现；预算来自 kernel.sandboxMs（与内核同一档）。
function Workbench:_bounded(fn, ...)
  local k = self.kernel
  local dsl = k and k.dsl
  if not (dsl and type(dsl.runBounded) == "function") then
    return pcall(fn, ...)
  end
  local ok, a, b = pcall(dsl.runBounded, fn, k.sandboxMs, ...)
  if not ok then return nil, tostring(a) end
  return a, b
end

function Workbench:_hasBuiltin(id)
  for _, b in ipairs(BUILTIN_VIEWS) do
    if b.id == id then return true end
  end
  return false
end

-- registry 是唯一视图权威：查得到就用它的规格，查不到才回落到 BUILTIN_VIEWS。
function Workbench:_viewSpec(id)
  if self.registry and self.registry.get then
    local ok, spec = pcall(function() return self.registry:get("view", id) end)
    if ok and type(spec) == "table" and spec.id then return spec, "registry" end
  end
  for _, b in ipairs(BUILTIN_VIEWS) do
    if b.id == id then return b, "builtin" end
  end
  return nil, nil
end

-- 视图实例的获取方式有两种：registry 规格给 mount(ctx)，内置模块给 mount(ctx)。
-- registry 的 mount 挂不起来（或只给了占位视图）时回落兜底表 —— 宁可画内置实现，
-- 也不给用户一块黑屏；原因留在 self.viewErrors 里给扩展页看。
function Workbench:_mountView(spec)
  if not spec or not spec.id then return nil end
  if self.views[spec.id] then return self.views[spec.id] end
  local view, err
  if type(spec.mount) == "function" then
    local ok, res = self:_bounded(spec.mount, self.ctx)
    if ok then view = res else err = res end
  elseif spec.module and type(spec.module.mount) == "function" then
    local ok, res = self:_bounded(spec.module.mount, self.ctx)
    if ok then view = res else err = res end
  end
  local usable = type(view) == "table" and not view.broken
    and (type(view.render) == "function" or type(view.show) == "function")
  if not usable and self:_hasBuiltin(spec.id) then
    local renderer = workbench.renderers[spec.id]
    if renderer then
      local ok, res = self:_bounded(renderer, self.ctx)
      if ok and type(res) == "table" then view = res end
    end
  end
  if type(view) ~= "table" then
    view = { broken = true, id = spec.id, error = tostring(err or "mount failed") }
  end
  if view.broken then
    self.viewErrors = self.viewErrors or {}
    self.viewErrors[spec.id] = tostring(view.error or "mount failed")
  end
  view.id = view.id or spec.id
  self.views[spec.id] = view
  return view
end

function Workbench:_mountCurrent()
  local spec = self:_specOf(self.viewId)
  if not spec then spec = select(1, self:_viewSpec(self.viewId)) end
  self.view = self:_mountView(spec)
  return self.view
end

function Workbench:setView(id)
  if not self:_specOf(id) then return false end
  if self.viewId == id then return false end
  self.viewId = id
  self:_mountCurrent()
  self:invalidate("rail")
  self:invalidate("main")
  return true
end

function Workbench:currentView() return self.view end

-- registry 变了（装了包）就重扫一遍；fingerprint 没变则什么都不做。
function Workbench:refresh()
  local spec = self:_specOf(self.viewId)
  if spec and type(spec.refresh) == "function" then
    pcall(spec.refresh, self.view, self.ctx)
  elseif self.view and type(self.view.refresh) == "function" then
    pcall(self.view.refresh, self.view, self.ctx)
  end
  self:invalidate("main")
end

function Workbench:destroy()
  for id, view in pairs(self.views or {}) do
    local spec = self:_specOf(id)
    if spec and type(spec.unmount) == "function" then pcall(spec.unmount, view) end
  end
  self.views = {}
  self.view = nil
  self.kit = nil
  self.ctx = nil
  self.dlg = nil
end

----------------------------------------------------------------------
-- 形态（四形态全保留，D4）
----------------------------------------------------------------------

function Workbench:setMode(mode)
  if mode == nil then return self.mode end
  local ok = false
  for _, m in ipairs(workbench.MODES) do if m == mode then ok = true end end
  if not ok then return self.mode end
  self.mode = mode
  self:invalidate()
  return self.mode
end

function Workbench:layoutMode() return self.mode end
function Workbench:isBar() return self.mode == "bar_bottom" or self.mode == "bar_side" end
function Workbench:isSmall() return self.mode == "small" end

-- /bar 在四形态间循环（与 v0.5.x 同一顺序）
function Workbench:cycleMode()
  local cur = 1
  for i, m in ipairs(workbench.MODES) do if m == self.mode then cur = i end end
  return self:setMode(workbench.MODES[(cur % #workbench.MODES) + 1])
end

----------------------------------------------------------------------
-- 布局：这里的每个数字都能被 golden 断言
----------------------------------------------------------------------

function Workbench:layout()
  local m = self.th.metrics
  local W, H = self.w or m.defaultW, self.h or m.defaultH
  local L = { w = W, h = H, mode = self.mode }

  if self.mode == "small" then
    -- 小窗的既定行为（v0.5.9 / D4）：状态行 + 最后一行输出 + **仍能输入**。
    -- 之前这里只给了 titlebar+main、composer 高度写 0，于是小窗里内容区全黑、打不了字。
    L.small = true
    local compH = math.min(m.composerH, H)
    local statusH = math.max(0, H - compH)
    L.titlebar = { x = 0, y = 0, w = W, h = 0 }
    L.main = { x = 0, y = 0, w = W, h = statusH }
    L.composer = { x = 0, y = statusH, w = W, h = compH }
    return L
  end

  local bar = self:isBar()
  local titleH = bar and 0 or m.titleH
  local railW = bar and 0 or m.railW
  local compH = math.min(m.composerH, H)
  -- 宽 < 760 自动折叠右上下文；栏形态本来就只留主视图
  local collapsed = bar or self.ctxCollapsed or W < m.narrowCtx
  local ctxW = 0
  if not collapsed then
    ctxW = math.min(m.ctxW, math.max(0, W - railW - 120))
  end
  local stripH = collapsed and not bar and m.rowH or 0
  local bodyH = math.max(0, H - titleH - compH - stripH)

  L.bar = bar
  -- 底边栏要的是"够显示状态 + 最后一行输出"，所以主视图压成单行；
  -- 侧边栏窄而高，日志照常多行滚动。
  L.compressed = (self.mode == "bar_bottom")
  L.collapsed = collapsed
  L.titlebar = { x = 0, y = 0, w = W, h = titleH }
  L.rail = { x = 0, y = titleH, w = railW, h = bodyH }
  L.main = { x = railW, y = titleH, w = math.max(0, W - railW - ctxW), h = bodyH }
  if collapsed then
    L.context = stripH > 0 and { x = 0, y = titleH + bodyH, w = W, h = stripH, strip = true } or nil
  else
    L.context = { x = W - ctxW, y = titleH, w = ctxW, h = bodyH }
  end
  L.composer = { x = 0, y = H - compH, w = W, h = compH }
  return L
end

----------------------------------------------------------------------
-- 绘制
----------------------------------------------------------------------

-- 状态改了必须真的让宿主重绘一次 —— 只记脏标记是不够的。
--
-- 这一条是整块 UI 的命门：invalidate 只改 kit 的 marks，谁也不会来调 paint；
-- 用户看到的就是「状态变了但像素不动」＝什么都点不动（真机实测：整个会话只画过一帧）。
-- 旧面板 panel.lua 里 self:repaint() 出现 28 次，就是为了这件事。
--
-- 为什么可以同步调、不必自己合并：dlg:repaint() 在 Aseprite 里只是标脏，
-- 真正的绘制发生在 UI 循环的下一帧，所以一次爆发里调 N 次只会画一帧。
function Workbench:invalidate(region)
  if not self.kit then return end
  self.kit:invalidate(region)
  self:_requestRepaint()
end

-- 请宿主重绘；绘制过程中再触发会自递归，用 _painting 挡掉 —— 但不能只是丢掉：
-- 记一个 deferred 标记，paint 收尾时发现有失效就再请一帧，否则"在回调/绘制里改的状态"
-- 会永远停留在旧像素上（真机自点击：切到小窗后画面全黑就是这么来的）。
function Workbench:_requestRepaint()
  if self._painting then
    self._repaintDeferred = true
    return false
  end
  local dlg = self.dlg
  if not dlg then return false end
  self.repaintCount = (self.repaintCount or 0) + 1
  local ok, err = pcall(function() dlg:repaint() end)
  if not ok then self.lastRepaintError = tostring(err) end
  return ok
end

-- 五区里只有这两处会因滚动/回显失效
function Workbench:invalidateMain() self:invalidate("main") end
function Workbench:invalidateComposer() self:invalidate("composer") end

function Workbench:setSize(w, h)
  if w == self.w and h == self.h then return false end
  self.w, self.h = w, h
  self:invalidate()
  return true
end

-- 换 gc（换 canvas / 新的一帧一个 GraphicsContext）只换指针，**不重建 kit**：
-- 重建会丢掉测量缓存（中文测量结果每帧白算一遍），更糟的是 self:invalidate() 会在
-- 绘制过程中再请一帧 —— 每帧都请，就变成无限重绘，真机上表现为画布全空。
function Workbench:_ensureKit(gc)
  if self.kit then
    if self.kit.gc ~= gc then
      self.kit.gc = gc
      self.kit:invalidate()      -- 纹理全失效：五区都重画，但**不**再请宿主帧
    end
    return self.kit
  end
  self.kit = kitMod.new(gc, self.th, { record = self.opts.record })
  if self.ctx then self.ctx.kit = self.kit end
  self.kit:invalidate()
  return self.kit
end

-- onpaint 里**绝不允许**有 Lua 错误逃出去：错误穿过 C++ 边界会让 Aseprite 直接以
-- 0xC000001D 退出（不是弹错误，是进程消失）。所以整帧包一层 pcall，把原因留在
-- self.lastPaintError 上给扩展页/测试读，画面最多少一块，绝不死。
function Workbench:paint(gc)
  self._painting = true
  local ok, err = pcall(self._paint, self, gc)
  self._painting = false
  if not ok then
    self.lastPaintError = tostring(err)
  else
    self.lastPaintError = nil
  end
  -- 本帧里有失效请求（被 _painting 挡下的那些）：再请一帧，别把变化留在旧像素上。
  -- 但要有上限：如果"画的过程中每帧都在失效"，补帧会变成无限重绘（真机上就是画布全空 + CPU 跑满）。
  if self._repaintDeferred then
    self._repaintDeferred = false
    self._deferStreak = (self._deferStreak or 0) + 1
    if self._deferStreak > 3 then
      self.lastDeferError = "repaint deferred " .. tostring(self._deferStreak) .. " frames in a row (stopped)"
      self._deferStreak = 0
    else
      self:_requestRepaint()
    end
  else
    self._deferStreak = 0
  end
  return ok
end

function Workbench:_paint(gc)
  if gc then
    self.w, self.h = gc.width, gc.height
  end
  local kit = self:_ensureKit(gc)
  if self.lastW ~= self.w or self.lastH ~= self.h then
    self.lastW, self.lastH = self.w, self.h
    kit:invalidate()
  end
  kit:begin()
  local L = self:layout()
  self.L = L

  if self.mode == "small" then
    if kit:dirty("main") then
      kit:region("main", L.main)
      self:drawBarMain(kit, L.main, true)
    end
    if kit:dirty("composer") and L.composer.h > 0 then
      kit:region("composer", L.composer)
      self:drawComposer(kit, L.composer)
    end
    return kit:finish()
  end

  if L.titlebar.h > 0 and kit:dirty("titlebar") then
    kit:region("titlebar", L.titlebar)
    self:drawTitlebar(kit, L.titlebar)
  end
  if L.rail and L.rail.w > 0 and kit:dirty("rail") then
    kit:region("rail", L.rail)
    self:drawRail(kit, L.rail)
  end
  if L.context and kit:dirty("context") then
    kit:region("context", L.context)
    self:drawContext(kit, L.context, L)
  end
  if kit:dirty("main") then
    kit:region("main", L.main)
    if L.compressed then self:drawBarMain(kit, L.main) else self:drawMain(kit, L.main) end
  end
  if kit:dirty("composer") then
    kit:region("composer", L.composer)
    self:drawComposer(kit, L.composer)
  end
  return kit:finish()
end

function Workbench:paintStats()
  return self.kit and self.kit.stats or { frames = 0, calls = 0, ms = 0, regions = {} }
end

----------------------------------------------------------------------
-- titlebar（30px）
----------------------------------------------------------------------

function Workbench:drawTitlebar(kit, r)
  local m = self.th.metrics
  kit:fill(r, "surface")
  kit:rule({ x = r.x, y = r.y + r.h - m.hair, w = r.w, h = m.hair }, "line")

  local ty = r.y + math.floor((r.h - m.lineH) / 2)
  local dr = kit:text({ x = r.x + 8, y = ty }, "◆", { tone = "accent" })
  local tr = kit:text({ x = dr.x + dr.w + 6, y = ty }, kit:pick("AI PIXEL COPILOT", "AI PIXEL COPILOT", { bold = true }),
                      { bold = true, tone = "text" })
  local docName = self.state.doc and self.state.doc.name or ""
  if docName ~= "" then
    kit:text({ x = tr.x + tr.w + 12, y = ty }, docName, { tone = "dim" })
  end

  -- 状态：● 已连接 · 模型。连不上时点变红、字变红（ui §1 第 5 条：状态永远可见）
  local ok = self.state.connected ~= false
  local dotTone = ok and "ok" or "err"
  local sx = r.x + math.floor(r.w / 2) - 40
  if sx < tr.x + tr.w + 100 then sx = tr.x + tr.w + 100 end
  local dot = kit:text({ x = sx, y = ty }, "●", { tone = dotTone })
  local status = self.state.status
  if status == nil or status == "" then
    status = ok and (i18n.isZh() and "已连接" or "connected") or (i18n.isZh() and "已断开" or "disconnected")
  end
  if self.state.busy then
    kit:spinner({ x = dot.x + dot.w + 6, y = ty }, self.state.spin or 0)
    kit:text({ x = dot.x + dot.w + 6 + 10, y = ty }, status, { tone = "busy" })
  else
    kit:text({ x = dot.x + dot.w + 6, y = ty }, status, { tone = ok and "dim" or "err" })
  end

  -- 右侧四键：▣ 形态 / ◫ 折叠上下文 / － 最小化 / × 关闭
  local btns = { "▣", "◫", "－", "×" }
  local bx = r.x + r.w - 8 - #btns * 20 + 4
  self.titleHits = {}
  for i, label in ipairs(btns) do
    local br = { x = bx + (i - 1) * 20, y = r.y + math.floor((r.h - 16) / 2), w = 16, h = 16 }
    local hover = self.state.hover == ("tb" .. i)
    kit:button(br, label, { hover = hover, focus = false })
    self.titleHits[#self.titleHits + 1] = { rect = br, kind = "tb", index = i, id = ({ "mode", "ctx", "min", "close" })[i] }
  end
  return r
end

----------------------------------------------------------------------
-- 左轨（56px）
----------------------------------------------------------------------

function Workbench:drawRail(kit, r)
  local m = self.th.metrics
  kit:fill(r, "surface")
  kit:rule({ x = r.x + r.w - m.hair, y = r.y, w = m.hair, h = r.h }, "line")
  self.railHits = {}

  local cell = 40
  local x = r.x + math.floor((r.w - cell) / 2)
  local y = r.y + 8
  for i, spec in ipairs(self.specs) do
    local cur = spec.id == self.viewId
    local hover = self.state.hover == ("rail" .. i)
    local cr = { x = x, y = y, w = cell, h = cell }
    if cur or hover then kit:fill(cr, cur and "surface2" or "surface2") end
    if cur then
      -- 当前视图：顶部一条 2px accent 竖条（ui §2）
      kit:fill({ x = r.x, y = y, w = m.accentBar, h = cell }, "accent")
    end
    local glyph = spec.icon or "·"
    local gw = kit:measure(glyph, {})
    kit:text({ x = x + math.floor((cell - gw) / 2), y = y + math.floor((cell - m.lineH) / 2) },
             glyph, { tone = cur and "accent" or "dim" })
    self.railHits[#self.railHits + 1] = { rect = cr, kind = "view", id = spec.id }
    y = y + cell + m.gap
  end

  -- 底部：新建 ⊕
  local nr = { x = x, y = r.y + r.h - cell - 8, w = cell, h = cell }
  if self.state.hover == "railNew" then kit:fill(nr, "surface2") end
  local nw = kit:measure("⊕", {})
  kit:text({ x = x + math.floor((cell - nw) / 2), y = nr.y + math.floor((cell - m.lineH) / 2) }, "⊕", { tone = "dim" })
  self.railHits[#self.railHits + 1] = { rect = nr, kind = "new" }
  return r
end

----------------------------------------------------------------------
-- 右上下文（240px，或折叠后 composer 上方的一行窄条）
----------------------------------------------------------------------

function Workbench:contextLines()
  local doc = self.state.doc or {}
  local zh = i18n.isZh()
  return {
    { label = zh and "名称" or "Name", value = doc.name or (zh and "未打开" or "no doc") },
    { label = zh and "尺寸" or "Size", value = string.format("%d×%d", doc.w or 0, doc.h or 0) },
    { label = zh and "图层" or "Layers", value = tostring(doc.layers or 0) },
    { label = zh and "帧" or "Frame", value = string.format("%d/%d", doc.frame or 0, doc.frames or 0) },
    { label = zh and "待办" or "Todo", value = tostring(self.state.todos or 0) },
    { label = zh and "本轮" or "Steps", value = string.format("%d %s %.1fs", self.state.steps or 0, zh and "步" or "steps", self.state.elapsed or 0) },
  }
end

function Workbench:drawContext(kit, r, L)
  local m = self.th.metrics
  kit:fill(r, "surface")
  if r.strip then
    -- 折叠态：三行关键信息压成一行（文档 / 待办 / 状态），不占竖直空间
    kit:rule({ x = r.x, y = r.y, w = r.w, h = m.hair }, "line")
    local lines = self:contextLines()
    local x = r.x + m.viewPad
    local picks = { 1, 5, 6 }
    for _, i in ipairs(picks) do
      local row = lines[i]
      if row then
        local lr = kit:text({ x = x, y = r.y + math.floor((r.h - m.lineH) / 2) }, row.label, { tone = "dim" })
        local vr = kit:text({ x = lr.x + lr.w + 6, y = lr.y }, row.value, { tone = "text" })
        x = vr.x + vr.w + 16
      end
    end
    return r
  end

  kit:rule({ x = r.x, y = r.y, w = m.hair, h = r.h }, "line")
  local lines = self:contextLines()
  local y = r.y + m.pad
  local header = kit:pick("文档", "DOCUMENT")
  kit:text({ x = r.x + m.pad, y = y }, header, { bold = true, tone = "dim" })
  y = y + m.lineH + m.gap
  local rowH = m.rowH
  for i = 1, 4 do
    local row = lines[i]
    kit:field({ x = r.x + m.pad, y = y, w = r.w - m.pad * 2, h = rowH }, row.label, row.value)
    y = y + rowH
  end
  y = y + m.gap
  kit:rule({ x = r.x + m.pad, y = y, w = r.w - m.pad * 2, h = m.hair }, "line")
  y = y + m.gap + 4
  kit:text({ x = r.x + m.pad, y = y }, kit:pick("状态", "STATUS"), { bold = true, tone = "dim" })
  y = y + m.lineH + m.gap
  for i = 5, 6 do
    local row = lines[i]
    kit:field({ x = r.x + m.pad, y = y, w = r.w - m.pad * 2, h = rowH }, row.label, row.value)
    y = y + rowH
  end
  return r
end

----------------------------------------------------------------------
-- 主视图
----------------------------------------------------------------------

function Workbench:drawMain(kit, r)
  kit:fill(r, "bg")
  local inner = { x = r.x, y = r.y, w = r.w, h = r.h }

  -- 断连 = 顶部红条：原因 + 可复制的起桥命令 + 重试（ui §5）
  if self.state.connected == false then
    local m = self.th.metrics
    local barH = math.min(math.max(m.rowH * 2, 28), r.h)
    local bar = { x = r.x, y = r.y, w = r.w, h = barH }
    kit:fill(bar, "surface2")
    kit:fill({ x = bar.x, y = bar.y, w = m.accentBar, h = barH }, "err")
    local reason = self.state.reason or (i18n.isZh() and "桥没连上" or "bridge not connected")
    kit:text({ x = bar.x + m.pad + 4, y = bar.y + 4 }, reason, { tone = "err" })
    local cmd = self.state.bridgeCmd or workbench.BRIDGE_CMD
    kit:text({ x = bar.x + m.pad + 4, y = bar.y + 4 + m.lineH }, cmd, { tone = "dim", mono = true })
    local label = kit:pick("重试", "Retry")
    local bw = kit:measure(label, {}) + 20
    local br = { x = bar.x + bar.w - m.pad - bw, y = bar.y + math.floor((barH - (m.lineH + 8)) / 2), w = bw, h = m.lineH + 8 }
    kit:button(br, label, { hover = self.state.hover == "retry" })
    self.retryHit = br
    inner = { x = r.x, y = r.y + barH, w = r.w, h = math.max(0, r.h - barH) }
  else
    self.retryHit = nil
  end

  -- 主视图标题行（视图名 + 视图内动作右对齐）由壳统一画：七个视图各画一遍就会
  -- 把 30px 高度和 12px 内边距散落七处，改一次要改七次。
  local m2 = self.th.metrics
  if inner.h > m2.titleH then
    local spec = self:_specOf(self.viewId)
    local titleR = { x = inner.x, y = inner.y, w = inner.w, h = m2.titleH }
    kit:fill(titleR, "surface")
    local ty = titleR.y + math.floor((m2.titleH - m2.lineH) / 2)
    local icon = spec and spec.icon or "·"
    local ir = kit:text({ x = titleR.x + m2.viewPad, y = ty }, icon, { tone = "accent" })
    -- pcall 的第一个返回值是"成功了吗"，不是被调函数的返回值 —— 别用 select(1, pcall(...))
    local titleText = nil
    if self.view and type(self.view.title) == "function" then
      local okTitle, res = pcall(self.view.title, self.view)
      if okTitle and type(res) == "string" then titleText = res end
    end
    if titleText == nil then titleText = (spec and spec.title) or self.viewId end
    kit:text({ x = ir.x + ir.w + 8, y = ty }, upperText(titleText), { bold = true, tone = "text" })
    self.actionHits = {}
    local actions = {}
    if self.view and type(self.view.actions) == "function" then
      local ok, res = pcall(self.view.actions, self.view, self.state)
      if ok and type(res) == "table" then actions = res end
    end
    local ax = titleR.x + titleR.w - m2.viewPad
    for i = #actions, 1, -1 do
      local a = actions[i]
      local w = kit:measure(a.label, {}) + 12
      ax = ax - w
      local ar = { x = ax, y = titleR.y + math.floor((m2.titleH - m2.lineH - 8) / 2), w = w, h = m2.lineH + 8 }
      kit:button(ar, a.label, { hover = self.state.hoverAction == a.id })
      self.actionHits[#self.actionHits + 1] = { rect = ar, kind = "action", id = a.id }
      ax = ax - 4
    end
    kit:rule({ x = titleR.x, y = titleR.y + m2.titleH - m2.hair, w = titleR.w, h = m2.hair }, "line")
    inner = { x = inner.x, y = inner.y + m2.titleH, w = inner.w, h = inner.h - m2.titleH }
  end

  -- 编辑态的字段 id 传给视图（设置页据此给那一行画 accent 竖条）
  if self.fieldEdit and type(self.fieldEdit.id) == "string" then
    self.state.fieldEditId = (self.fieldEdit.id:gsub("^settings%.", ""))
  else
    self.state.fieldEditId = nil
  end

  if self.view and not self.view.broken and type(self.view.render) == "function" then
    local ok, err = self:_bounded(self.view.render, self.view, kit, inner, self.state)
    if not ok then
      -- 视图崩了不能让壳黑屏：把原因留在 main 上，也留一份给扩展页/测试读
      self.lastViewError = tostring(err)
      kit:text({ x = inner.x + 12, y = inner.y + 12 }, "view render failed: " .. tostring(err), { tone = "err" })
    else
      self.lastViewError = nil
    end
  elseif self.view and self.view.broken then
    kit:text({ x = inner.x + 12, y = inner.y + 12 },
             (i18n.isZh() and "这个视图挂载失败：" or "this view failed to mount: ") .. tostring(self.view.error or ""),
             { tone = "err" })
  end

  if self.paletteOpen then self:drawPalette(kit, inner) end
  return r
end

-- 栏形态的主视图：压成单行（状态 + 最后一行输出）
function Workbench:drawBarMain(kit, r, small)
  kit:fill(r, "surface")
  local m = self.th.metrics
  local y = r.y + math.floor((r.h - m.lineH) / 2)
  local ok = self.state.connected ~= false
  kit:text({ x = 8, y = y }, "●", { tone = ok and "ok" or "err" })
  local status = self.state.status
  if status == nil or status == "" then
    status = ok and (i18n.isZh() and "已连接" or "connected") or (i18n.isZh() and "已断开" or "disconnected")
  end
  local sr = kit:text({ x = 22, y = y }, status, { tone = ok and "dim" or "err" })
  local last = self.state.lastLine or ""
  if last ~= "" then kit:text({ x = sr.x + sr.w + 12, y = y }, last, { tone = "text" }) end
  return r
end

----------------------------------------------------------------------
-- 命令面板（Ctrl+K）：模糊搜索所有 registry.command
----------------------------------------------------------------------

function Workbench:commands()
  local out, seen = {}, {}
  if self.registry and self.registry.list then
    local ok, list = pcall(function() return self.registry:list("command") end)
    if ok and type(list) == "table" then
      for _, c in ipairs(list) do
        if c and c.id and not seen[c.id] then
          seen[c.id] = true
          out[#out + 1] = c
        end
      end
    end
  end
  -- 壳自带的命令永远排在最后（registry 里有同名 id 时以 registry 为准）
  for _, c in ipairs(workbench.BUILTIN_COMMANDS) do
    if c and c.id and not seen[c.id] then
      seen[c.id] = true
      out[#out + 1] = c
    end
  end
  return out
end

-- 逃生口：关掉工作台，把 agent 的面板换回旧终端面板并打开它。
-- 为什么还要换回来：main.lua 的 swapAgentPanel 已经把 agent.panel 换成了适配器，
-- 适配器的 show() 又指回工作台 —— 不换回去的话 agent:open() 会把工作台再显示一次。
function Workbench:useLegacyPanel()
  local a = self.agent
  self.legacyMode = true
  if a and type(a.panel) == "table" and a.panel.wb == self and a.panel.fallback then
    a.panel = a.panel.fallback
  end
  self:hide()
  local opened = false
  if a and type(a.open) == "function" then
    local ok, err = pcall(a.open, a)
    opened = ok
    self.lastLegacyError = (not ok) and tostring(err) or nil
  end
  -- 回到旧面板后给它留一句话，用户知道自己为什么换了界面
  local target = a and a.panel or nil
  if target and type(target.log) == "function" then
    pcall(target.log, target, i18n.isZh() and "已切到旧面板（工作台可用 Ctrl+K → legacy 再切回）"
                                      or "switched to the legacy panel", "info")
  end
  return opened
end

function Workbench:paletteMatches()
  local q = lowerText(self.paletteQuery)
  local out = {}
  for _, c in ipairs(self:commands()) do
    local hay = lowerText(tostring(c.id) .. " " .. tostring(c.title or "") .. " " .. tostring(c.keys or ""))
    if q == "" or hay:find(q, 1, true) then out[#out + 1] = c end
  end
  return out
end

function Workbench:drawPalette(kit, r)
  local m = self.th.metrics
  local w = math.min(360, r.w - 24)
  local items = self:paletteMatches()
  local h = math.min(r.h - 24, m.rowH * (math.min(#items, 8) + 1) + 8)
  local box = { x = r.x + math.floor((r.w - w) / 2), y = r.y + 16, w = w, h = h }
  kit:fill(box, "surface")
  kit:frameRect(box, "lineHi")
  kit:text({ x = box.x + m.pad, y = box.y + 4 }, "> " .. (self.paletteQuery or ""), { tone = "text" })
  local rows = {}
  for i, c in ipairs(items) do
    if i > 8 then break end
    rows[#rows + 1] = { text = tostring(c.title or c.id), tone = "text", badge = c.keys }
  end
  self.paletteLayout = kit:list({ x = box.x, y = box.y + m.rowH, w = box.w, h = box.h - m.rowH },
                                rows, { hover = self.paletteSel })
  return box
end

----------------------------------------------------------------------
-- composer（40px）
----------------------------------------------------------------------

function Workbench:drawComposer(kit, r)
  local m = self.th.metrics
  kit:fill(r, "surface")
  kit:rule({ x = r.x, y = r.y, w = r.w, h = m.hair }, "line")
  local focused = self.state.focus == "composer"
  if focused then kit:fill({ x = r.x, y = r.y, w = m.accentBar, h = r.h }, "accent") end

  local y = r.y + math.floor((r.h - m.lineH) / 2)
  local left
  if self.state.busy then
    left = kit:spinner({ x = r.x + m.pad + 4, y = y }, self.state.spin or 0)
  else
    left = kit:text({ x = r.x + m.pad + 4, y = y }, "▶", { tone = focused and "accent" or "dim" })
  end

  local right = { x = r.x + r.w - m.pad - 4 }
  local stopTone = self.state.busy and "err" or "faint"
  local stopR = kit:text({ x = right.x - 10, y = y }, "⏹", { tone = stopTone })
  local clipTone = self.state.attachments and "text" or "faint"
  local clipR = kit:text({ x = stopR.x - 24, y = y }, "📎", { tone = clipTone })
  local enterR = kit:text({ x = clipR.x - 24, y = y }, "⏎", { tone = "dim" })

  -- 三个图标必须登记命中区：画出来却点不动，就是"界面上有一堆死按钮"。
  -- 命中区比字形宽（20px），2x 缩放下也按得住。
  self.composerHits = {
    { rect = { x = stopR.x - 4, y = r.y + 4, w = 20, h = r.h - 8 }, kind = "composer", id = "stop" },
    { rect = { x = clipR.x - 4, y = r.y + 4, w = 20, h = r.h - 8 }, kind = "composer", id = "attach" },
    { rect = { x = enterR.x - 4, y = r.y + 4, w = 20, h = r.h - 8 }, kind = "composer", id = "enter" },
  }

  local tx = left.x + left.w + 8
  local maxW = enterR.x - 8 - tx

  -- 字段编辑态：左边是字段名（accent），右边是当前值；apiKey 只显示掩码
  local fe = self.fieldEdit
  if fe then
    local label = tostring(fe.label or fe.id or "") .. (i18n.isZh() and "：" or ": ")
    local lr = kit:text({ x = tx, y = y }, label, { tone = "accent" })
    tx = lr.x + lr.w
    maxW = enterR.x - 8 - tx
  end

  local text = self.input or ""
  if text == "" then
    -- 提示文字给光标让出一个字符位：不然光标会压在提示的第一个字上，
    -- 看起来像"文字被画了两遍"（这条是看真机截图发现的）
    local ph
    if fe then
      ph = fe.mask and (i18n.isZh() and "••••（留空 = 保持不变）" or "•••• (blank = keep current)")
                       or (i18n.isZh() and "回车确认 / Esc 取消" or "Enter to confirm / Esc to cancel")
    else
      ph = kit:pick("说点什么，或敲 / 叫命令…", "say something, or press / for commands")
    end
    kit:text({ x = tx + 8, y = y }, ph, { tone = "faint" })
    self.caretX = tx
  else
    local tw = kit:measure(text, {})
    local draw = text
    if tw > maxW and maxW > 0 then
      -- 只显示尾部：输入回显的语义是"我正在打的这几个字"。
      -- 按【字符】从末尾回退（utf8.offset），按字节回退会切断多字节序列，
      -- 画出去就是非法 UTF-8 —— 那是能让 Aseprite 直接退出的一种输入。
      local len = utf8.len(text) or 0
      local acc, keep = 0, 0
      for n = 1, len do
        local from = utf8.offset(text, -(n - 1))
        local to = utf8.offset(text, -n + 1) or #text
        local ch = text:sub(from, to)
        local cw = kit:measure(ch, {})
        if acc + cw > maxW then break end
        acc = acc + cw
        keep = n
      end
      draw = keep > 0 and kit.u8sub(text, -keep) or ""
    end
    local tr = kit:text({ x = tx, y = y }, draw, { tone = "text" })
    self.caretX = tr.x + tr.w
  end

  -- 光标位：空输入时画在提示文字起点，有字时画在字尾。
  -- 原生输入行收起来之后，这个光标就是"可以打字"的唯一可见凭证。
  kit:fill({ x = self.caretX + 1, y = y, w = 1, h = m.lineH }, self.inputOpen and "accent" or "dim")

  if self.completionOpen then
    self:drawCompletion(kit, r)
  end
  return r
end

-- 补全弹层：/ 开头的词补 registry.command 的 id
function Workbench:drawCompletion(kit, r)
  local m = self.th.metrics
  local items = self:completionMatches()
  if #items == 0 then return end
  local h = math.min(#items, 5) * m.rowH + 4
  local box = { x = r.x + m.pad, y = r.y - h, w = 240, h = h }
  kit:fill(box, "surface")
  kit:frameRect(box, "lineHi")
  local rows = {}
  for i, c in ipairs(items) do
    if i > 5 then break end
    rows[#rows + 1] = { text = "/" .. tostring(c.id), tone = "text" }
  end
  self.completionLayout = kit:list({ x = box.x, y = box.y + 2, w = box.w, h = box.h - 4 }, rows, { hover = self.completionSel })
  return box
end

function Workbench:completionMatches()
  local text = self.input or ""
  local word = text:match("^/([%w_%-]*)$")
  if not word then return {} end
  local out = {}
  for _, c in ipairs(self:commands()) do
    local id = tostring(c.id or "")
    if word == "" or lowerText(id:sub(1, #word)) == lowerText(word) then out[#out + 1] = c end
  end
  return out
end

----------------------------------------------------------------------
-- 键盘路由（ui §6）
----------------------------------------------------------------------

function Workbench:_key(ev)
  if type(ev) == "string" then return { code = ev } end
  if ev == nil then return { code = nil } end
  local k = ev.key or ev
  return {
    code = k.code or ev.code,
    ctrl = (k.ctrl or ev.ctrl) and true or false,
    alt = (k.alt or ev.alt) and true or false,
    shift = (k.shift or ev.shift) and true or false,
  }
end

-- 返回 true 表示"壳吃掉了这个键"，宿主不要再处理
function Workbench:key(ev)
  local k = self:_key(ev)
  local code = k.code

  if k.ctrl and (code == "K" or code == "k") then
    self:openPalette()
    return true
  end
  if k.alt then
    local n = tonumber(tostring(code or ""))
    if n then return self:switchViewIndex(n) end
    if code == "C" or code == "c" then
      self:toggleContext()
      return true
    end
  end
  if code == "Tab" then return self:cycleFocus() end
  if code == "Escape" then
    local lvl = self:escape()
    return lvl ~= nil
  end
  if code == "/" and (self.state.focus ~= "composer") then
    self:focusComposer()
    self:setInput("/")
    self.completionOpen = true
    return true
  end
  if code == "ArrowUp" then
    return self:nav(-1)
  end
  if code == "ArrowDown" then
    return self:nav(1)
  end
  return false
end

function Workbench:switchViewIndex(n)
  local spec = self.specs and self.specs[n]
  if not spec then return false end
  self:setView(spec.id)
  return true
end

function Workbench:toggleContext()
  self.ctxCollapsed = not self.ctxCollapsed
  self:invalidate("context")
  self:invalidate("main")
  return self.ctxCollapsed
end

function Workbench:cycleFocus()
  local order = { "rail", "main", "context", "composer" }
  local cur = 1
  for i, f in ipairs(order) do if f == self.state.focus then cur = i end end
  self.state.focus = order[(cur % #order) + 1]
  self:invalidate()
  return true
end

function Workbench:focusComposer()
  self.state.focus = "composer"
  self:invalidate("composer")
  if self.dlg then
    pcall(function() self.dlg:modify({ id = "input", focus = true }) end)
  end
  return true
end

function Workbench:openPalette()
  self.paletteOpen = true
  self.paletteQuery = ""
  self.paletteSel = 1
  self.completionOpen = false
  self:invalidate("main")
  self:invalidate("composer")
  return true
end

function Workbench:closePalette()
  if not self.paletteOpen then return false end
  self.paletteOpen = false
  self:invalidate("main")
  return true
end

function Workbench:nav(delta)
  if self.paletteOpen then
    local n = #self:paletteMatches()
    if n > 0 then
      self.paletteSel = util.clamp((self.paletteSel or 1) + delta, 1, n)
      self:invalidate("main")
      return true
    end
    return false
  end
  if self.completionOpen then
    local n = #self:completionMatches()
    if n > 0 then
      self.completionSel = util.clamp((self.completionSel or 1) + delta, 1, n)
      self:invalidate("composer")
      return true
    end
    return false
  end
  -- 视图内列表导航 / composer 历史交给视图
  if self.view and type(self.view.nav) == "function" then
    local ok, handled = pcall(self.view.nav, self.view, delta)
    if ok and handled then
      self:invalidateMain()
      self.lastNavError = nil
      return true
    end
    -- 视图 nav 出错时留痕：不然"按了没反应"完全没法排查
    if not ok then self.lastNavError = tostring(handled) end
  end
  return false
end

-- Esc 三级：关补全 -> 关弹层 -> 中断当前轮（2 秒内再按一次才真中断）
function Workbench:escape()
  -- 编辑态：Esc 取消字段编辑（不写盘），优先级最高
  if self.fieldEdit then
    self:cancelFieldEdit()
    return "field"
  end
  if self.completionOpen then
    self.completionOpen = false
    self:invalidate("composer")
    return "completion"
  end
  if self.paletteOpen then
    self.paletteOpen = false
    self:invalidate("main")
    return "popup"
  end
  -- Esc 收起输入行：不提交、草稿留在 self.input 里（再点一下就能接着写）
  if self.inputOpen then
    self:closeInput()
    return "input"
  end
  if self.state.busy then
    local t = self.now()
    if self.interruptArmed and (t - self.interruptArmed) <= 2 then
      self.interruptArmed = nil
      self:interrupt()
      return "interrupt"
    end
    self.interruptArmed = t
    self.state.interruptHint = i18n.isZh() and "再按一次 Esc 中断本轮" or "press Esc again to stop"
    self:invalidate("composer")
    self:invalidate("titlebar")
    return "armed"
  end
  return nil
end

function Workbench:interrupt()
  if self.agent and type(self.agent.interrupt) == "function" then
    pcall(self.agent.interrupt, self.agent)
  end
  if self.opts.onInterrupt then pcall(self.opts.onInterrupt) end
  self.state.busy = false
  self:invalidate()
  return true
end

----------------------------------------------------------------------
-- 输入（只脏 composer；回显绝不整屏）
----------------------------------------------------------------------

function Workbench:setInput(text)
  self.input = tostring(text or "")
  self.completionOpen = self.input:sub(1, 1) == "/"
  self:invalidate("composer")
  return self.input
end

function Workbench:getInput() return self.input or "" end

function Workbench:setHistory(list, pos)
  self.history = list or {}
  self.historyPos = pos or 0
end

function Workbench:submit()
  -- 字段编辑态：Enter 是"确认写回"，不是发给模型
  if self.fieldEdit then return self:commitFieldEdit() end
  local text = tostring(self.input or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self:setInput("")
  self.completionOpen = false
  -- 提交即收：输入行是一次性的，常驻的只有自绘 composer
  self:closeInput()
  if text == "" then return false end
  if self.paletteOpen then
    local items = self:paletteMatches()
    local c = items[self.paletteSel or 1]
    self:closePalette()
    if c then
      self:runCommand(c, text)
      return true
    end
  end
  if self.agent and type(self.agent.send) == "function" then
    local ok = pcall(self.agent.send, self.agent, text)
    if not ok then self:log(text, "user") end
  else
    self:log(text, "user")
  end
  return true
end

function Workbench:runCommand(c, arg)
  if c and type(c.run) == "function" then
    pcall(c.run, self.ctx, arg)
    self:invalidate()
    return true
  end
  return false
end

----------------------------------------------------------------------
-- 日志（只脏 main）
----------------------------------------------------------------------

function Workbench:log(text, kind, meta)
  local cv = self.views and self.views.console
  if not cv and self:_specOf("console") then cv = self:_mountView(self:_specOf("console")) end
  if cv and type(cv.log) == "function" then
    pcall(cv.log, cv, text, kind, meta)
  end
  self.state.lastLine = tostring(text or "")
  self:invalidate("main")
  self:invalidate("bar")
  return true
end

function Workbench:setBusy(busy, status)
  self.state.busy = busy and true or false
  if status then self.state.status = status end
  self.interruptArmed = nil
  self:invalidate("titlebar")
  self:invalidate("composer")
  return self.state.busy
end

function Workbench:setConnected(ok, detail)
  self.state.connected = ok ~= false
  if detail then
    self.state.reason = detail.reason
    self.state.bridgeCmd = detail.cmd
  end
  self:invalidate("titlebar")
  self:invalidate("main")
  return self.state.connected
end

function Workbench:setDoc(doc)
  self.state.doc = doc
  self:invalidate("context")
  return doc
end

function Workbench:setStatus(status)
  self.state.status = status
  self:invalidate("titlebar")
  return status
end

----------------------------------------------------------------------
-- 鼠标
----------------------------------------------------------------------

-- canvas 事件的统一入口：按旧面板踩出来的规矩
--   1) mousedown 只管焦点（不抢输入法），**激活在 mouseup**；
--   2) ev.button 缺字段就当左键，坐标一律 tonumber 兜 0 —— 真机上坐标给 nil
--      曾在 mousedown 里抛错，错误穿进 C++ 之后整个面板就"点不动"了；
--   3) 每个回调整体 pcall，错误只进 lastInputError，绝不外泄。
local LEFT_BUTTON = (type(MouseButton) == "table" and MouseButton.LEFT) or 1

function Workbench:_evPoint(ev)
  ev = ev or {}
  local x = tonumber(ev.x) or 0
  local y = tonumber(ev.y) or 0
  local btn = ev.button
  local isLeft = (btn == nil) or (btn == LEFT_BUTTON)
  return x, y, isLeft
end

function Workbench:_input(label, fn, ...)
  local ok, res = pcall(fn, ...)
  if not ok then
    self.lastInputError = label .. ": " .. tostring(res)
    return nil
  end
  self.lastInputError = nil
  return res
end

function Workbench:mouseDown(ev)
  local x, y, isLeft = self:_evPoint(ev)
  if not isLeft then return false end
  -- 点自绘 composer = 想打字：这一刻才把原生输入行浮出来并给焦点。
  -- 别的地方抢焦点会打断输入法组合（旧面板同款判断）。
  local L = self.L or self:layout()
  if L.composer and L.composer.h > 0 and y >= L.composer.y then
    self:focusComposer()
    self:openInput()
  end
  return true
end

function Workbench:mouseUp(ev)
  local x, y, isLeft = self:_evPoint(ev)
  if not isLeft then return nil end
  return self:mouse("click", x, y)
end

function Workbench:mouseMove(ev)
  local x, y = self:_evPoint(ev)
  return self:mouse("move", x, y)
end

function Workbench:mouseWheel(ev)
  ev = ev or {}
  local x, y = self:_evPoint(ev)
  local dy = tonumber(ev.wheelDelta) or tonumber(ev.delta) or 0
  return self:wheel(x, y, dy)
end

-- 面板注册给 canvas 的那组回调（build 与测试共用同一份，避免"测的不是真机跑的"）
-- 是不是"敲了一个可打印字符"？带 Ctrl/Alt 的一律不算（那是快捷键）。
function Workbench:_typedChar(ev)
  if not ev then return nil end
  local k = ev.key or ev
  if k.ctrl or k.alt then return nil end
  local u = k.unicode
  if type(u) == "string" then
    local b = u:byte(1)
    if b and b >= 32 and b ~= 127 then return u end
  end
  local c = k.code
  if type(c) == "string" and #c == 1 then
    local b = c:byte(1)
    if b and b >= 32 and b < 127 then return c end
  end
  return nil
end

function Workbench:handlers()
  return {
    onpaint = function(ev) self:paint(ev and ev.context or nil) end,
    onkeydown = function(ev)
      self:_input("key", function()
        -- 快捷键优先（Ctrl+K / Alt+数字 / / / Esc…）
        local handled = self:key(ev)
        -- 输入行收着的时候，敲一个可打印字符应当"叫出"输入行并把这一下吞进来，
        -- 否则用户看到的是"键盘没反应"。
        if not handled and not self.inputOpen then
          local ch = self:_typedChar(ev)
          if ch then
            self:openInput()
            self:setInput((self.input or "") .. ch)
            handled = true
          end
        end
        if handled and ev and ev.stopPropagation then ev.stopPropagation() end
      end)
    end,
    onmousedown = function(ev) self:_input("mousedown", function() return self:mouseDown(ev) end) end,
    onmouseup = function(ev) self:_input("mouseup", function() return self:mouseUp(ev) end) end,
    onmousemove = function(ev) self:_input("mousemove", function() return self:mouseMove(ev) end) end,
    onwheel = function(ev) self:_input("wheel", function() return self:mouseWheel(ev) end) end,
  }
end

function Workbench:mouse(kind, x, y)
  if kind == "move" then
    local h = self:hitTest(x, y)
    local tag = nil
    if h then
      tag = h.kind == "tb" and ("tb" .. h.index)
        or h.kind == "view" and ("rail" .. (self:_railIndexOf(h.id) or 0))
        or h.kind == "new" and "railNew"
        or h.kind == "retry" and "retry"
    end
    -- 视图内部的行也要有悬浮反馈：没有反馈用户就以为"点不了"（设置页/记忆页这类）
    local rowIdx = h and h.index or nil
    if tag ~= self.state.hover or rowIdx ~= self.state.hoverRow then
      self.state.hover = tag
      self.state.hoverRow = rowIdx
      self:invalidate("titlebar")
      self:invalidate("rail")
      self:invalidate("main")
    end
    return tag
  end
  if kind == "click" then
    local h = self:hitTest(x, y)
    if not h then return "none" end
    if h.kind == "tb" then
      if h.id == "ctx" then return self:toggleContext() and "toggle-ctx" or "expand-ctx" end
      if h.id == "mode" then return "mode:" .. tostring(self:cycleMode()) end
      -- － 最小化 = 切到小窗形态（再点一次回来）。只 return 一个字符串等于死按钮。
      if h.id == "min" then return "min:" .. tostring(self:toggleSmall()) end
      -- × 只关面板，不关 Aseprite —— 用户点的是工作台的叉
      if h.id == "close" then self:hide(); return "close" end
    elseif h.kind == "view" then
      local switched = self:setView(h.id)
      if not switched then
        -- 点的是当前视图：切视图是空操作，但"把键盘焦点交给主视图"是有用的真实动作
        self.state.focus = "main"
        self:invalidate("main")
      end
      return "view:" .. h.id
    elseif h.kind == "new" then
      return self:railNew()
    elseif h.kind == "retry" then
      self:setConnected(true)
      return "retry"
    elseif h.kind == "composer" then
      return self:composerAction(h.id)
    elseif h.kind == "action" then
      -- 主视图标题行右侧的视图内动作（预览/应用/让它提议/重扫/检索/Chat▾/⊕…）
      return self:viewAction(h.id)
    end
    -- 视图自己画的按钮（启用/停用、算子行、示例…）：交给视图处理，壳不猜语义
    if self.view and type(self.view.click) == "function" then
      local ok, handled = pcall(self.view.click, self.view, h)
      if ok and handled then
        -- 视图内部状态改了（例如扩展开关 / 打开原生设置窗），画面必须跟着变；
        -- 模态窗关掉后宿主可能把工作台一起收掉 → _afterModal 兜一层
        self:_afterModal()
        self:invalidate("main")
        return "view-click:" .. tostring(h.kind)
      end
    end
    return h.kind
  end
  return nil
end

----------------------------------------------------------------------
-- 死按钮防治：每个画出来的命中区都必须"点了有可观察变化"
--
-- 允许"不接线"，但必须**有理由 + 有可见反馈**（记进 noop 表并往会话里打一行）。
-- 空函数（只 return 一个字符串、什么都不做）一律不许过 —— reachability_test 会钉住。
----------------------------------------------------------------------

workbench.NOOP_REASONS = {
  ["action.preview"] = "v1 没有预览通道：算子要么真执行（可 Ctrl+Z 撤销），要么不动画布",
  ["action.propose"] = "提议链路要等 agent 的 proposal 接口（T1 侧），现在只记录请求",
  ["action.new"] = "风格新建要写 bridge/data/styles，属于桥侧能力，v1 骨架只读",
  ["composer.attach"] = "没有 agent 时无处可选图（正常安装下走 agent:action(upload)）",
  ["rail.new"] = "没有 agent 时无法新建对话（正常安装下走 agent:action(conversation_new)）",
}

-- 记录一次"没有真正动作、但已给用户反馈"的点击
function Workbench:noop(id, detail)
  local reason = workbench.NOOP_REASONS[id] or "未接线"
  self.noops = self.noops or {}
  self.noops[id] = (self.noops[id] or 0) + 1
  local text = i18n.isZh() and ("【未接线】" .. tostring(detail or id) .. "：" .. reason)
                            or ("[not wired] " .. tostring(detail or id) .. ": " .. reason)
  self:log(text, "warn")
  return "noop:" .. tostring(id)
end

-- 最小化 = 小窗形态；再点一次回到原形态
function Workbench:toggleSmall()
  if self.mode == "small" then
    local back = self._modeBeforeSmall or "panel"
    self:setMode(back)
    return back
  end
  self._modeBeforeSmall = self.mode
  self:setMode("small")
  return "small"
end

-- 左轨底部的 ⊕：新建对话（旧面板里就是 conversation_new 这条动作）
function Workbench:railNew()
  local a = self.agent
  if a and type(a.action) == "function" then
    local ok = pcall(a.action, a, "conversation_new")
    if ok then
      self:_afterModal()
      return "rail-new"
    end
  end
  return self:noop("rail.new", "新建对话")
end

----------------------------------------------------------------------
-- 画布内字段编辑（不弹旧面板的原生设置窗）
--
-- 复用的还是那套已验证的机制：原生 entry（中文输入）+ 哨兵差分 + composer 回显 +
-- submit/Esc。没有新造控件：编辑态 = composer 变成"提示 + 当前值"的单行编辑器。
----------------------------------------------------------------------

-- spec = { id, label, value, mask?, hint?, onCommit=function(text) -> ok, err }
function Workbench:beginFieldEdit(spec)
  if type(spec) ~= "table" or spec.id == nil then return false end
  self.fieldEdit = spec
  self:openInput()
  self:setInput(tostring(spec.value or ""))
  self.state.focus = "composer"
  self:invalidate("composer")
  if spec.hint then self:log(tostring(spec.hint), "info") end
  return true
end

function Workbench:cancelFieldEdit()
  if not self.fieldEdit then return false end
  local fe = self.fieldEdit
  self.fieldEdit = nil
  self:setInput("")
  self:closeInput()
  self:log(string.format(i18n.isZh() and "已取消编辑 %s（未保存）" or "cancelled %s (not saved)",
    tostring(fe.label or fe.id)), "info")
  self:invalidate()
  return true
end

function Workbench:commitFieldEdit()
  local fe = self.fieldEdit
  if not fe then return false end
  local text = self:getInput()
  local ok, err = true, nil
  if type(fe.onCommit) == "function" then
    ok, err = fe.onCommit(text)
  end
  if ok == false or ok == nil then
    -- 保留输入与编辑态，让用户改完再按一次回车
    self:log(string.format(i18n.isZh() and "保存失败：%s" or "save failed: %s", tostring(err or "?")), "error")
    self:invalidate("composer")
    return false
  end
  self.fieldEdit = nil
  self:setInput("")
  self:closeInput()
  self:invalidate()
  return true
end

-- composer 右侧三个图标
function Workbench:composerAction(id)
  if id == "enter" then
    local sent = self:submit()
    return sent and "submit" or "submit-empty"
  elseif id == "attach" then
    -- 附件 = 旧面板那条「选图/上传」通路（agent:pickFile → 原生文件选择器）
    local a = self.agent
    if a and type(a.action) == "function" then
      local ok = pcall(a.action, a, "upload")
      if ok then
        self:_afterModal()
        return "attach"
      end
    end
    return self:noop("composer.attach", "选择图片")
  elseif id == "stop" then
    if not self.state.busy then
      self:log(i18n.isZh() and "当前没有正在跑的轮次" or "nothing is running", "info")
      return "stop-idle"
    end
    self:interrupt()
    return "stop"
  end
  return self:noop("composer." .. tostring(id), tostring(id))
end

-- 主视图标题行右侧的视图内动作：交给视图的 action(id)，视图没实现就记 noop
function Workbench:viewAction(id)
  local v = self.view
  if v and type(v.action) == "function" then
    local ok, handled = pcall(v.action, v, id, self.state)
    if ok and handled then
      self:_afterModal()
      self:invalidate()
      return "view-action:" .. tostring(id)
    end
  end
  return self:noop("action." .. tostring(id), tostring(id))
end

-- 原生模态窗（设置窗 / 文件选择器）关掉之后，宿主有可能把工作台一起收掉。
-- 这里兜一层：只要工作台自己的 dlg 还在就重新显示，用户看到的是"设置窗关了、面板还在"。
function Workbench:_afterModal()
  if self.legacyMode then return end
  if not self.dlg then return end
  if self.shown then return end
  local ok = pcall(function() self.dlg:show{ wait = false } end)
  self.shown = true
  self.modalRecovered = (self.modalRecovered or 0) + 1
  if ok then self:invalidate() end
  return ok
end

function Workbench:_railIndexOf(id)
  for i, s in ipairs(self.specs or {}) do if s.id == id then return i end end
  return nil
end

-- 命中顺序：后画的在上面（composer > main > context > rail > titlebar）
function Workbench:hitTest(x, y)
  local L = self.L or self:layout()
  local function scan(list)
    for i = #(list or {}), 1, -1 do
      local h = list[i]
      if h.rect and x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h then
        return h
      end
    end
    return nil
  end
  if self.retryHit and x >= self.retryHit.x and x < self.retryHit.x + self.retryHit.w
     and y >= self.retryHit.y and y < self.retryHit.y + self.retryHit.h then
    return { kind = "retry" }
  end
  -- composer 画在最后 = 最上层，命中优先级最高
  local h = scan(self.composerHits)
  if h then return h end
  h = scan(self.actionHits)
  if h then return h end
  h = scan(self.titleHits)
  if h then return h end
  h = scan(self.railHits)
  if h then return h end
  -- 主视图内部的命中框（视图自己画的）由视图判定
  if self.view and type(self.view.hitAt) == "function" then
    local ok, res = pcall(self.view.hitAt, self.view, x, y)
    if ok and res then return res end
  end
  return nil
end

function Workbench:wheel(x, y, dy)
  local L = self.L or self:layout()
  if L.composer and y >= L.composer.y then return "composer" end
  if self.view and type(self.view.wheel) == "function" then
    local ok, handled = pcall(self.view.wheel, self.view, dy)
    if ok and handled then
      self:invalidate("main")
      return "main"
    end
  end
  return nil
end

----------------------------------------------------------------------
-- 宿主接线条（T1 在 main.lua 里一行调完）
----------------------------------------------------------------------

-- 把工作台挂进一个现有 Dialog：canvas 自绘 + 底部 entry（中文输入必须走 entry）+ 磁吸按钮。
function Workbench:build(dlg)
  if self.dlg then return self.dlg end
  if not dlg then return nil end
  local m = self.th.metrics
  -- 五个回调都从 handlers() 来：测试驱动的是同一份函数，不是它的影子实现
  local h = self:handlers()
  dlg:canvas{
    id = "screen",
    width = self.w,
    height = self.h,
    autoscaling = true,
    onpaint = h.onpaint,
    onkeydown = h.onkeydown,
    onmousedown = h.onmousedown,
    onmouseup = h.onmouseup,
    onmousemove = h.onmousemove,
    onwheel = h.onwheel,
  }
  dlg:newrow()
  -- 初始隐藏：常驻的白横条就是用户要去掉的那个"控制台遗留"。
  -- entry 留着是因为中文输入只走原生 ui::Entry（自绘 canvas 收不到 IME）。
  dlg:entry{ id = "input", text = workbench.SENTINEL, hexpand = true, visible = false,
             onchange = function() self:onEntryChange() end }
  dlg:samerow()
  -- 磁吸按钮：focus=true 的按钮吃 ENTER（README 约束 5），所以提交挂在它身上。
  -- 它必须和 entry **同显同隐** —— 按钮藏着，ENTER 就没人捕获。
  dlg:button{ id = "send", text = "⏎", hexpand = false, focus = true, visible = false,
              onclick = function() self:submit() end }
  self.dlg = dlg
  return dlg
end

-- Entry 的内容永远是 SENTINEL（一个空格）；每次变化按"差"算成插入 / 退格。
-- 为什么这么绕：Dialog 没有"读 entry 文本"的接口，只有 dlg.data.input（STATUS 约束 4）。
workbench.SENTINEL = " "

function Workbench:onEntryChange()
  if self.entrySyncing or not self.dlg then return end
  local raw = tostring((self.dlg.data and self.dlg.data.input) or "")
  if raw == workbench.SENTINEL then return end           -- 只是移动光标
  if raw == "" then
    -- 哨兵被删掉 = 用户按了退格
    local s = self.input or ""
    local i = utf8.offset(s, -1)
    self:setInput(i and s:sub(1, i - 1) or "")
    -- **必须复位光标**：Entry::onSetText 只把 caret 往下 clamp 不挪到末尾（entry.cpp:506），
    -- 退格后文本被清空 → caret 停在 0 → 下一次退格前面没有字符 → onchange 不触发
    -- → self.input 再也不删。真机表现就是"打了字删不掉"。
    self:_resetEntry(true)
  else
    local inserted = raw:gsub(workbench.SENTINEL, "", 1) -- 只吃一个哨兵（用户输入的空格要留住）
    if inserted ~= "" then self:setInput((self.input or "") .. inserted) end
    -- 追加时 caret 已在末尾（打字是往后插），不需要那圈焦点舞；省掉能少一次重新布局
    self:_resetEntry(false)
  end
  self:invalidate("composer")
end

----------------------------------------------------------------------
-- 原生输入行：按需浮出（点 composer / 敲字才出现），提交或 Esc 收起
--
-- visible 切换是一次 dlg:modify，而 modify 会触发重新布局、Aseprite 顺手把窗口
-- 撑回"内容自然尺寸"——用户手动缩过窗口，这一下就跳回去了。旧面板为此写了
-- Panel:_preserveBounds（panel.lua:655），这里照抄同一手法，不发明新的。
----------------------------------------------------------------------

function Workbench:_preserveBounds(fn)
  local before = nil
  if self.dlg and self.shown then
    local ok, b = pcall(function() return self.dlg.bounds end)
    if ok and b and (b.width or 0) > 0 and (b.height or 0) > 0 then
      before = { x = b.x, y = b.y, w = b.width, h = b.height }
    end
  end

  local okCall, err = pcall(fn)

  if before and self.dlg then
    local ok2, b2 = pcall(function() return self.dlg.bounds end)
    if ok2 and b2 and ((b2.width or 0) ~= before.w or (b2.height or 0) ~= before.h) then
      pcall(function()
        self.dlg.bounds = Rectangle(before.x, before.y, before.w, before.h)
      end)
    end
  end

  if not okCall then error(err) end
end

function Workbench:focusCanvas()
  if not self.dlg then return false end
  local ok = pcall(function() self.dlg:modify{ id = "screen", focus = true } end)
  self.state.focus = "composer"
  return ok
end

function Workbench:setInputRowVisible(on)
  on = on and true or false
  self.inputOpen = on
  local dlg = self.dlg
  if dlg then
    self:_preserveBounds(function()
      pcall(function() dlg:modify{ id = "input", visible = on } end)
      pcall(function() dlg:modify{ id = "send", visible = on } end)
    end)
    if on then
      -- 焦点给 entry（不然打不了字、也开不了输入法）
      self:_preserveBounds(function()
        pcall(function() dlg:modify{ id = "input", focus = true } end)
      end)
    else
      self:focusCanvas()
    end
  end
  self:invalidate("composer")
  return self.inputOpen
end

function Workbench:openInput()
  if self.inputOpen then return true end
  return self:setInputRowVisible(true)
end

function Workbench:closeInput()
  if not self.inputOpen then return false end
  self:setInputRowVisible(false)
  return true
end

-- 把 Entry 恢复成"只有一个哨兵"，并可选把光标送回末尾
function Workbench:_resetEntry(restoreCaret)
  if not self.dlg then return end
  -- entrySyncing 挡住复位本身触发的 onchange（它不该再跑一遍插入/退格逻辑）
  self.entrySyncing = true
  -- 复位是 1~3 次 modify，而 modify 会触发重新布局、可能把窗口撑回自然尺寸 ——
  -- 每敲一键都跳一次窗口，所以整段必须包在 _preserveBounds 里。
  local ok, err = pcall(function()
    self:_preserveBounds(function()
      self.dlg:modify{ id = "input", text = workbench.SENTINEL }
      if restoreCaret then
        -- 送光标到末尾的唯一 Lua 途径是让焦点绕一圈：先给 send 再给 input，
        -- 触发 kFocusEnterMessage → selectAllText → setCaretPos(末尾)（entry.cpp:283-295）。
        self.dlg:modify{ id = "send", focus = true }
        self.dlg:modify{ id = "input", focus = true }
      end
    end)
  end)
  self.entrySyncing = false
  if not ok then self.lastEntryError = tostring(err) end
end

----------------------------------------------------------------------
-- 显示 / 隐藏
----------------------------------------------------------------------

function Workbench:isShown() return self.shown == true end

function Workbench:open() return self:show() end

-- 默认 900x620 是 ui §2 的规格尺寸，但这台机器 UI 缩放 2x —— 写死会把窗口顶出屏幕。
-- 所以开窗前按主窗口尺寸收敛一次（读不到就保持规格尺寸，无头下也一样）。
function Workbench:fitToScreen()
  local m = self.th.metrics
  local W, H = nil, nil
  pcall(function() W = app.window.width end)
  pcall(function() H = app.window.height end)
  if not W or not H or W <= 0 or H <= 0 then return self.w, self.h end
  local w = util.clamp(self.w, m.minW, math.max(m.minW, W - 24))
  local h = util.clamp(self.h, m.minH, math.max(m.minH, H - 80))
  if w ~= self.w or h ~= self.h then self:setSize(w, h) end
  return self.w, self.h
end

function Workbench:show()
  -- 上次是"关掉"的：重建一个新的 Dialog（关掉的控件不能再拿来 show）
  if self.dlgClosed then
    self.dlg = nil
    self.dlgClosed = false
  end
  self:fitToScreen()
  -- newDialog 是给单测的注入口（无头下 Dialog{} 返回 nil，测不了"重建"这条路径）
  local dlgObj = nil
  if type(self.opts.newDialog) == "function" then
    dlgObj = self.opts.newDialog()
  else
    dlgObj = Dialog{ title = "AI Pixel Copilot", onclose = function() self.shown = false end }
  end
  local dlg = self:build(dlgObj)
  if not dlg then
    -- 无头（-b）下 Dialog 构造返回 nil；把状态标成"已打开"以便单测继续跑
    self.shown = true
    return self
  end
  self:invalidate()
  pcall(function() dlg:show{ wait = false } end)
  self.shown = true
  pcall(function() self.dlg:modify{ id = "input", focus = true } end)
  return self
end

-- 关窗口。注意两点（真机踩出来的）：
--   1) 从自己的鼠标回调里调 dlg:close()，宿主有时会忽略这次关闭（窗口还在，只是 shown=false）
--      → 除了立刻关，还排一个一次性 Timer 再关一次（GUI 下 Timer 会 tick；无头下不 tick，无副作用）。
--   2) 关掉的 Dialog 不能再用：打 dlgClosed 标记，下次 show() 重建一个干净的。
function Workbench:hide()
  self.shown = false
  local dlg = self.dlg
  if not dlg then return self end

  local ok1, err1 = pcall(function() dlg:close() end)
  if not ok1 then self.lastCloseError = tostring(err1) end

  if type(Timer) == "table" then
    local t
    t = Timer{
      interval = 0.01,
      ontick = function()
        pcall(function() t:stop() end)
        local ok2, err2 = pcall(function() dlg:close() end)
        if not ok2 then self.lastCloseError = tostring(err2) end
      end,
    }
  end

  self.dlgClosed = true
  return self
end

function Workbench:repaint()
  if not (self.shown and self.dlg) then return false end
  return self:_requestRepaint()
end

return workbench
