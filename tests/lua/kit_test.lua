-- tests/lua/kit_test.lua -- 视图原语 + 三区工作台 + golden layout
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/kit_test.lua
--
-- 为什么能无头跑：Kit 只吃 GraphicsContext（这里给假 gc）与 theme；工作台只吃
-- registry/host/ledger 的**接口**（这里给假实现）。所以"样式"是可测的：
-- 给定 rect 集合与状态，输出的绘制调用序列就确定。
--
-- golden 只比 **rect 与调用名**，不比字体位图 —— 换台机器字体不同也不该红。
-- 快照文件：tests/lua/kit_golden_900x620.txt / kit_golden_640x420.txt
-- 第一次跑会生成（自举），之后逐条比对；不一致时把实际序列写到
-- tests/lua/kit_test.actual.txt 供 diff。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local i18n = require("lib.i18n")
-- 语言会影响标签宽度 -> golden 的 rect。测试里把语言钉成英文，
-- 这样快照在任何机器上都一致（中文渲染另由 GUI 截图验）。
i18n._resetLang()
i18n.resolve("en", "en")

local kitMod = require("kernel.kit")
local themeMod = require("lib.theme")
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

----------------------------------------------------------------------
-- 假 GraphicsContext：只实现 kit 用到的六个方法
----------------------------------------------------------------------

-- zeroCjk=true 时中文串量出来是 0 —— 用来验"缺字回落英文"
local function fakeGC(w, h, zeroCjk)
  local g = { width = w or 900, height = h or 620, color = nil,
              rects = {}, texts = {}, images = {}, measureN = 0, flushN = 0 }
  g.measureText = function(_, s)
    g.measureN = g.measureN + 1
    s = tostring(s or "")
    local nch = utf8.len(s) or #s
    if zeroCjk and nch ~= #s then return { width = 0, height = 0 } end
    return { width = nch * 6, height = 12 }
  end
  g.fillRect = function(_, rc) g.rects[#g.rects + 1] = { x = rc.x, y = rc.y, w = rc.width or rc.w, h = rc.height or rc.h } end
  g.fillText = function(_, s, x, y) g.texts[#g.texts + 1] = { text = tostring(s), x = x, y = y } end
  g.drawImage = function(_, img, x, y) g.images[#g.images + 1] = { img = img, x = x, y = y } end
  g.flush = function() g.flushN = g.flushN + 1 end
  return g
end

local function drewText(gc, s)
  for _, t in ipairs(gc.texts) do if t.text == s then return true end end
  return false
end

local function drewContaining(gc, part)
  for _, t in ipairs(gc.texts) do if t.text:find(part, 1, true) then return true end end
  return false
end

----------------------------------------------------------------------
-- 假 kernel：registry / host / ledger 只给工作台真正会调到的接口
----------------------------------------------------------------------

local function fakeRegistry()
  local kinds = { view = {}, command = {}, op = {}, action = {}, tool = {} }
  local fp = 0
  local reg = {}
  -- op 规格的键是 name，其余是 id；两者都可能是 nil，nil == nil 会把两次注册当成同一个
  local function keyOf(s)
    if s == nil then return nil end
    if s.id ~= nil then return s.id end
    return s.name
  end
  function reg:define(kind, spec)
    kinds[kind] = kinds[kind] or {}
    local list = kinds[kind]
    local k = keyOf(spec)
    if k ~= nil then
      for i, s in ipairs(list) do
        if keyOf(s) == k then list[i] = spec; fp = fp + 1; return true end
      end
    end
    list[#list + 1] = spec
    fp = fp + 1
    return true
  end
  function reg:get(kind, id)
    for _, s in ipairs(kinds[kind] or {}) do
      if keyOf(s) == id then return s end
    end
    return nil
  end
  function reg:list(kind)
    local out = {}
    for _, s in ipairs(kinds[kind] or {}) do out[#out + 1] = s end
    table.sort(out, function(a, b)
      local ao, bo = a.order or 100, b.order or 100
      if ao ~= bo then return ao < bo end
      return tostring(a.id or a.name) < tostring(b.id or b.name)
    end)
    return out
  end
  function reg:remove(kind, id) end
  function reg:kinds()
    local out = {}
    for k, v in pairs(kinds) do if #v > 0 then out[#out + 1] = k end end
    return out
  end
  function reg:fingerprint() return "fp" .. tostring(fp) end
  return reg
end

local function fakeHost()
  local host = { applied = {} }
  function host:active() return nil end
  function host:apply(label, fn) self.applied[#self.applied + 1] = label; return true end
  function host:notify() end
  function host:alert() end
  function host:versions()
    return { list = function() return { { name = "sharpen", detail = "256px" } } end }
  end
  return host
end

-- 数据放 packList/healthData：字段名不能和方法同名，否则 self.health 指回方法自己
local function fakeLedger(packs, health)
  local l = { packList = packs or {}, healthData = health or {}, enabled = {} }
  function l:scan() return self.packList end
  function l:health() return self.healthData end
  function l:enable(id) self.enabled[id] = true; return true end
  function l:disable(id) self.enabled[id] = false; return true end
  function l:rollback(id) return { ok = true, restoredTo = id } end
  function l:journal() end
  return l
end

local function fakeAgent()
  local a = { sent = {}, interrupted = 0 }
  function a:send(t) self.sent[#self.sent + 1] = t; return true end
  function a:interrupt() self.interrupted = self.interrupted + 1; return true end
  return a
end

local function newWB(opts)
  opts = opts or {}
  local reg = opts.registry or fakeRegistry()
  local kernel = {
    registry = reg,
    host = opts.host or fakeHost(),
    ledger = opts.ledger or fakeLedger(),
    bus = { on = function() return 1 end, emit = function() end },
  }
  local wb = workbench.new({
    width = opts.width or 900,
    height = opts.height or 620,
    now = opts.now,
    viewId = opts.viewId,
  })
  wb:mount(kernel, opts.agent or fakeAgent())
  return wb, kernel
end

----------------------------------------------------------------------
-- 1. kit 原语
----------------------------------------------------------------------

print("== kit: 测量与缓存 ==")
do
  local th = themeMod.new({ name = "dark" })
  local gc = fakeGC(900, 620)
  local kit = kitMod.new(gc, th)
  local w1 = kit:measure("abcd")
  eq(w1, 24, "measure 走 gc 实测（4 字 x 6px）")
  local n = gc.measureN
  kit:measure("abcd")
  eq(gc.measureN, n, "同 (text,style) 二次测量命中缓存，不再问 gc")
  kit:measure("abcd", { bold = true })
  eq(gc.measureN, n + 1, "换 style 才重新测量")

  local w0 = kit:measure("锐化")
  eq(w0, 12, "有字形时中文按实测宽（假 gc 给 6px/字，两个字 = 12）")

  local gc0 = fakeGC(900, 620, true)
  local kit0 = kitMod.new(gc0, th)
  eq(kit0:measure("锐化"), 0, "缺字时 measureText 返回 0 —— kit 如实返回 0，不猜宽度")
  eq(kit0:pick("锐化", "sharpen"), "sharpen", "缺字回落英文（ui §3.2）")
  local kitZh = kitMod.new(gc, themeMod.new({ name = "dark", locale = "zh" }))
  eq(kitZh:pick("锐化", "sharpen"), "锐化", "有字形时用中文")
end

print("== kit: 原语矩形 ==")
do
  local th = themeMod.new({})
  local gc = fakeGC(900, 620)
  local kit = kitMod.new(gc, th)
  local r = kit:text({ x = 10, y = 20 }, "abc", { tone = "dim" })
  eq(r.x, 10, "text 返回 rect.x")
  eq(r.w, 18, "text 返回实测宽")
  ok(r.h > 0, "text 返回行高", r.h)

  local fr = kit:field({ x = 0, y = 0, w = 200, h = 18 }, "layers", "4")
  local valRect
  for i = #kit.calls, 1, -1 do
    local c = kit.calls[i]
    if c.op == "text" and c.w == 6 then valRect = c end
  end
  ok(valRect ~= nil, "field 画出了 value")
  eq(valRect and (valRect.x + valRect.w), 200, "field 的 value 右对齐到 rect 右边（等宽成列）")

  local br = kit:badge({ x = 0, y = 0 }, "12", "ok")
  eq(br.w, 12 + 16, "badge 宽 = 文本宽 + 4x8 内边距（左右各 8）")
  eq(br.h, 14 + 8, "badge 高 = 行高 + 上下各 4")

  ok(kit:hit({ x = 0, y = 0, w = 10, h = 10 }, 5, 5), "hit 命中内部点")
  ok(not kit:hit({ x = 0, y = 0, w = 10, h = 10 }, 10, 5), "hit 不含右边界（半开区间）")
  ok(not kit:hit(nil, 1, 1), "hit(nil) 安全")

  local tone = kit:tone("ok")
  ok(tone ~= nil, "tone('ok') 返回颜色")
  ok(kit:tone("不存在的名字") ~= nil, "未知 tone 回落 text 而不是 nil")
end

print("== kit: 列表 ==")
do
  local th = themeMod.new({})
  local gc = fakeGC(900, 620)
  local kit = kitMod.new(gc, th)
  local items = {}
  for i = 1, 5 do items[i] = { text = "row" .. i, tone = "text" } end
  local layout = kit:list({ x = 0, y = 0, w = 300, h = 18 * 3 }, items, { sel = 2, hover = 3 })
  eq(#layout.rows, 3, "list 只排可见行（h/rowH）")
  eq(layout.rowH, 18, "行高 18（14 + 4 间距栅格）")
  eq(layout.count, 5, "layout 报告总条数")
  eq(layout.maxScroll, 2, "maxScroll = count - visible")

  local accentBar
  for _, c in ipairs(kit.calls) do
    if c.op == "fill" and c.w == 2 then accentBar = c end
  end
  ok(accentBar ~= nil, "选中行左侧画出 2px accent 竖条")
  eq(accentBar and accentBar.x, 0, "accent 竖条贴列表左边界")

  local long = string.rep("x", 200)
  kit:list({ x = 0, y = 0, w = 60, h = 18 }, { { text = long } }, {})
  local last = gc.texts[#gc.texts].text
  eq(last:sub(-3), "…", "超宽行截断并以省略号收尾（不折行，保住 18px 栅格）")
end

print("== kit: 脏区与帧 ==")
do
  local th = themeMod.new({})
  local gc = fakeGC(900, 620)
  local kit = kitMod.new(gc, th)
  local d = kit:dirtySet()
  eq(#d, 5, "新建时五个脏区全脏（首帧必然画满）")
  eq(d[1], "titlebar", "脏区顺序固定 titlebar 优先")
  kit:begin()
  kit:region("main", { x = 0, y = 0, w = 10, h = 10 })
  kit:text({ x = 0, y = 0 }, "a", {})
  kit:finish()
  ok(not kit:dirty("main"), "收帧只清掉本帧画过的区")
  ok(kit:dirty("rail"), "没画过的区仍然脏")
  -- 真实事故回归：GraphicsContext 是 userdata，读一个不存在的字段会**抛错**而不是返回 nil。
  -- 那个错误发生在 onpaint 里，会穿过 C++ 边界让 Aseprite 以 0xC000001D 退出。
  -- 所以收帧时任何 gc 字段都不许探测（这里用"读未知字段就抛错"的桩把它钉住）。
  local gcStrict = fakeGC(200, 200)
  setmetatable(gcStrict, { __index = function(_, k) error("Field " .. tostring(k) .. " does not exist") end })
  local kitStrict = kitMod.new(gcStrict, th)
  local okFinish = pcall(function()
    kitStrict:begin()
    kitStrict:region("main", { x = 0, y = 0, w = 10, h = 10 })
    kitStrict:text({ x = 0, y = 0 }, "a", {})
    kitStrict:finish()
  end)
  ok(okFinish, "收帧不探测 gc 的字段（读不存在的字段会抛错，能崩宿主）")
  ok(kit.stats.regions.main == 1, "统计记录了 main 画过 1 帧")
end

----------------------------------------------------------------------
-- 2. theme：令牌与 accent 派生
----------------------------------------------------------------------

print("== kit: UTF-8 安全（非法 UTF-8 送进 fillText 会让宿主直接退出）==")
do
  eq(workbench.upperText("会话"), "会话", "中文不做字节级大写（会切坏多字节序列）")
  eq(workbench.upperText("console"), "CONSOLE", "纯 ASCII 才大写")
  eq(workbench.lowerText("会话 Chat"), "会话 Chat", "含中文的串不做字节级小写")
  eq(workbench.lowerText("Console"), "console", "纯 ASCII 才小写")

  local th = themeMod.new({})
  local gc = fakeGC(900, 620)
  local kit = kitMod.new(gc, th)
  eq(kitMod.u8sub("会话测试", 1, 2), "会话", "u8sub 按字符切（不是字节）")
  eq(kitMod.u8sub("会话测试", -2), "测试", "u8sub 负数从尾部按字符数")
  eq(kitMod.u8sub("会话测试", 1, 99), "会话测试", "u8sub 上界越界自动收口")
  ok(utf8.len(kitMod.u8sub("会话测试", 1, 1)) ~= nil, "u8sub 的产物一定是合法 UTF-8")

  -- 画出去的文字必须是合法 UTF-8：全部 _G 观察一遍比逐个断言更严
  kit:begin()
  kit:region("main", { x = 0, y = 0, w = 400, h = 200 })
  kit:text({ x = 0, y = 0 }, "会话 Chat 001.ase", {})
  kit:text({ x = 0, y = 20 }, kitMod.u8sub("中文很长很长很长", 1, 3), {})
  kit:button({ x = 0, y = 40, w = 120, h = 18 }, "会话 Chat▾", {})
  kit:badge({ x = 0, y = 60 }, "12", "ok")
  kit:list({ x = 0, y = 80, w = 100, h = 40 }, { { text = string.rep("字", 40) } }, {})
  local bad = nil
  for _, txt in ipairs(gc.texts) do
    if utf8.len(txt.text) == nil then bad = txt.text end
  end
  ok(bad == nil, "一帧里所有 fillText 的字符串都是合法 UTF-8", bad)
  kit:finish()
end

print("== kit: 假粗只对纯 ASCII 生效（中文偏移双画会糊成一团）==")
do
  local th = themeMod.new({ name = "dark", locale = "zh" })

  -- 中文 + bold：只许画一次
  local gcZh = fakeGC(900, 620)
  local kitZhB = kitMod.new(gcZh, th)
  kitZhB:begin()
  kitZhB:region("main", { x = 0, y = 0, w = 400, h = 100 })
  kitZhB:text({ x = 10, y = 10 }, "加强明暗对比", { bold = true, tone = "text" })
  kitZhB:finish()
  eq(#gcZh.texts, 1, "含中文的 bold 文本只发出 1 次 text 绘制")
  local zhCall = kitZhB.calls[1]
  eq(zhCall and zhCall.double, false, "中文 bold 不标记 double（不做偏移双画）")

  -- 纯 ASCII + bold：照旧两次
  local gcEn = fakeGC(900, 620)
  local kitEnB = kitMod.new(gcEn, th)
  kitEnB:begin()
  kitEnB:region("main", { x = 0, y = 0, w = 400, h = 100 })
  kitEnB:text({ x = 10, y = 10 }, "CONSOLE", { bold = true, tone = "text" })
  kitEnB:finish()
  eq(#gcEn.texts, 2, "纯 ASCII 的 bold 文本发出 2 次 text 绘制（假粗）")
  eq(gcEn.texts[1].text, gcEn.texts[2].text, "两次画的是同一串")
  eq(gcEn.texts[2].x, gcEn.texts[1].x + 1, "第二次偏移 1px（这才是假粗）")

  -- 不加 bold：任何语种都只画一次
  local gcPlain = fakeGC(900, 620)
  local kitPlain = kitMod.new(gcPlain, th)
  kitPlain:text({ x = 10, y = 10 }, "加强明暗对比", { tone = "dim" })
  eq(#gcPlain.texts, 1, "非 bold 的中文只画一次")

  -- 半角符号/数字/空格也算 ASCII，别误伤
  local gcMix = fakeGC(900, 620)
  local kitMix = kitMod.new(gcMix, th)
  kitMix:text({ x = 10, y = 10 }, "PACKS 1.0", { bold = true })
  eq(#gcMix.texts, 2, "ASCII + 数字 + 空格的 bold 仍然双画")
  eq(kitMod.isAsciiText("加强"), false, "isAsciiText 认得出中文")
  eq(kitMod.isAsciiText("PACKS 1.0"), true, "isAsciiText 认得出纯 ASCII")

  -- 全帧不变式（中文界面）：整帧里凡出现「同一串在 x+1 处再画一次」，那串必须是纯 ASCII。
  -- 这条才是能兜住「任何新加的 bold 中文」的那张网。
  local zhWB = workbench.new({
    width = 900, height = 620,
    theme = themeMod.new({ name = "dark", locale = "zh" }),
  })
  zhWB:mount(nil, { docName = function() return "001.ase" end })
  zhWB:setSize(900, 620)
  zhWB:setDoc({ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 })
  zhWB:log("把这层的红色换深一点", "user")
  local gcZhFrame = fakeGC(900, 620)
  zhWB:invalidate()
  zhWB:paint(gcZhFrame)

  -- 同一串在一个 x+1 的位置重复出现 => 假粗。扫一遍实际 fillText。
  local seen, doubled = {}, {}
  for _, t2 in ipairs(gcZhFrame.texts) do
    local key = tostring(t2.y) .. "|" .. tostring(t2.text)
    if seen[key] then doubled[#doubled + 1] = t2.text end
    seen[key] = true
  end
  local badZh = nil
  for _, txt in ipairs(doubled) do
    if not kitMod.isAsciiText(txt) then badZh = txt; break end
  end
  ok(badZh == nil, "中文界面整帧：没有任何中文串被偏移双画（假粗）", badZh)

  -- 中文界面确实出现了中文标题（不然上一条是空转）
  local hasCjk = false
  for _, t2 in ipairs(gcZhFrame.texts) do
    if not kitMod.isAsciiText(t2.text) then hasCjk = true; break end
  end
  ok(hasCjk, "中文界面整帧里确实有中文文本（不变式不是空转）")
end

print("== theme: 令牌 ==")
do
  eq(themeMod.TOKENS.dark.bg, "#111318", "bg 令牌 = #111318（ui §3.1）")
  eq(themeMod.DEFAULT_ACCENT, "#6ea8fe", "缺省 accent = #6ea8fe")
  ok(themeMod.TOKENS.light ~= nil and themeMod.TOKENS.light.bg ~= themeMod.TOKENS.dark.bg, "浅色同构存在且底色不同")
  eq(#themeMod.SPACE, 4, "栅格只有四档 4/8/12/16")
  eq(themeMod.SPACE[1], 4, "栅格第一档是 4")
  eq(themeMod.METRICS.railW, 56, "左轨 56px")
  eq(themeMod.METRICS.ctxW, 240, "右上下文 240px")
  eq(themeMod.METRICS.composerH, 40, "composer 40px")
  eq(themeMod.METRICS.titleH, 30, "titlebar 30px")
  local th = themeMod.new({ name = "dark" })
  ok(th.colors.bg ~= nil, "theme.new 把 hex 转成 Color")
  eq(th.accentHex, "#6ea8fe", "没给调色板时 accent 保持品牌蓝（D4：行为与旧版一致）")
end

print("== theme: accent 从调色板派生 ==")
do
  local hex = themeMod.deriveAccent({})
  eq(hex, "#6ea8fe", "空调色板 -> 品牌蓝")
  hex = themeMod.deriveAccent({ { 0, 0, 0 }, { 16, 16, 16 }, { 255, 255, 255 } })
  eq(hex, "#6ea8fe", "全黑全白（无彩度）-> 品牌蓝")
  hex = themeMod.deriveAccent({ { 128, 128, 128 }, { 200, 200, 200 } })
  eq(hex, "#6ea8fe", "全灰 -> 品牌蓝")

  local red = themeMod.deriveAccent({ { 255, 0, 0 }, { 128, 128, 128 } })
  local r, g, b = themeMod.toRgb(red)
  ok(r > 200, "彩度最高的红被选中并抬亮（R 主导）", red)
  eq(g, b, "只改明度不改色相：红派生后 G == B")
  ok(r > g, "红的派生色仍然偏红")

  local green = themeMod.deriveAccent({ { 0, 255, 0 } })
  local gr, gg, gb = themeMod.toRgb(green)
  ok(gg > 200, "绿的派生色 G 主导", green)
  eq(gr, gb, "绿派生后 R == B")

  local blue = themeMod.deriveAccent({ { 46, 134, 222 } })
  local br, bg, bb = themeMod.toRgb(blue)
  ok(bb > br and bb > bg, "蓝派生后 B 主导", blue)

  -- 彩度最高的那个说了算：纯红(240) 压过 亮蓝(157)
  local mixed = themeMod.deriveAccent({ { 46, 134, 222 }, { 255, 0, 0 } })
  local mr = themeMod.toRgb(mixed)
  ok(mr > 200, "两个候选里取彩度最高的那个（纯红）", mixed)

  eq(themeMod.deriveAccent({ { 255, 0, 0 }, { 128, 128, 128 } }),
     themeMod.deriveAccent({ { 128, 128, 128 }, { 255, 0, 0 } }),
     "同色集换个顺序结果相同（确定性）")
  eq(themeMod.deriveAccent({ "#FF0000" }), red, "接受 #RRGGBB 输入")
  eq(themeMod.deriveAccent({ "#F00" }), red, "接受 #RGB 短写")
  eq(themeMod.deriveAccent({ Color(255, 0, 0) }), red, "接受 Color 对象")
  eq(themeMod.deriveAccent({ { r = 255, g = 0, b = 0 } }), red, "接受 {r,g,b}")
  ok(#red == 7 and red:sub(1, 1) == "#", "输出是 7 位 hex", red)
end

print("== theme: sprite 调色板 ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  local list = themeMod.paletteOf(spr)
  ok(list ~= nil and #list > 0, "能从真 sprite 取到调色板颜色", list and #list)
  local hex = themeMod.accentForSprite(spr)
  ok(hex ~= nil and type(hex) == "string", "accentForSprite 返回 hex", hex)
  eq(themeMod.accentForSprite(nil), "#6ea8fe", "没有 sprite 时回落品牌蓝")
  -- 把索引 3 改成饱和红：派生结果必须是红系
  local okSet = pcall(function() spr.palettes[1]:setColor(3, Color(255, 0, 0)) end)
  if okSet then
    local h2 = themeMod.accentForSprite(spr)
    local r2 = themeMod.toRgb(h2)
    ok(r2 > 150, "调色板里出现饱和红后 accent 跟着变红", h2)
  else
    ok(true, "本机 Palette:setColor 不可用，跳过写色断言")
  end
end

----------------------------------------------------------------------
-- 3. 三区布局（900x620 / 640x420）
----------------------------------------------------------------------

print("== workbench: 布局 ==")
do
  local wb = newWB({ width = 900, height = 620 })
  wb:setSize(900, 620)
  local L = wb:layout()
  eq(L.titlebar.x, 0, "titlebar 贴左上")
  eq(L.titlebar.h, 30, "900x620：titlebar 30px")
  eq(L.rail.w, 56, "900x620：左轨 56px")
  eq(L.context.w, 240, "900x620：右上下文 240px")
  eq(L.composer.h, 40, "900x620：composer 40px")
  eq(L.composer.y, 580, "900x620：composer 贴在底边（620-40）")
  eq(L.main.x, 56, "主视图从 56px 开始")
  eq(L.main.w, 900 - 56 - 240, "主视图吃掉剩余宽度")
  eq(L.main.h, 620 - 30 - 40, "主视图吃掉剩余高度")
  eq(L.rail.h, L.main.h, "左轨与主视图等高")
  eq(L.main.y + L.main.h, L.composer.y, "主视图底边正好接 composer（不留缝）")
  eq(wb:currentView().id, "console", "默认视图 = console")

  local wb2 = newWB({ width = 640, height = 420 })
  wb2:setSize(640, 420)
  local L2 = wb2:layout()
  eq(L2.context.strip, true, "640 宽 < 760：右上下文自动折叠成窄条")
  eq(L2.context.w, 640, "折叠后的窄条占满整宽")
  eq(L2.context.h, 18, "折叠窄条高 18（= 一行）")
  eq(L2.main.w, 640 - 56, "折叠后主视图吃掉上下文的宽度")
  eq(L2.main.h, 420 - 30 - 40 - 18, "折叠后主视图高度扣掉窄条")
  eq(L2.titlebar.h, 30, "640x420 仍有 titlebar")
  eq(L2.composer.y, 380, "640x420：composer 在 380")
end

----------------------------------------------------------------------
-- 4. 脏区分级（ui §7）
----------------------------------------------------------------------

print("== workbench: 五个脏区独立失效 ==")
do
  local wb = newWB({ width = 900, height = 620 })
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  local st = wb:paintStats()
  eq(st.regions.titlebar, 1, "首帧画了 titlebar")
  eq(st.regions.rail, 1, "首帧画了 rail")
  eq(st.regions.context, 1, "首帧画了 context")
  eq(st.regions.main, 1, "首帧画了 main")
  eq(st.regions.composer, 1, "首帧画了 composer")

  -- 什么都没有变化 -> 一个都不画
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.main, 1, "无失效时不重画 main（禁止整屏重绘）")
  eq(st.regions.composer, 1, "无失效时不重画 composer")
  eq(#wb.kit.calls, 0, "无失效时这一帧没有产生任何绘制调用")

  -- 输入回显 -> 只脏 composer
  wb:setInput("abc")
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.composer, 2, "输入回显只重画 composer")
  eq(st.regions.main, 1, "输入回显不重画 main")
  eq(st.regions.rail, 1, "输入回显不重画 rail")
  eq(st.regions.titlebar, 1, "输入回显不重画 titlebar")
  eq(st.regions.context, 1, "输入回显不重画 context")

  -- 滚动 -> 只脏 main（先灌够内容，空会话滚不动是正确行为）
  for i = 1, 60 do wb:log("line " .. i, "info") end
  wb:invalidate("main")
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.main, 2, "追加日志只重画 main")
  wb:wheel(400, 300, 1)
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.main, 3, "滚动只重画 main")
  eq(st.regions.composer, 2, "滚动不重画 composer")

  -- Alt+C -> context + main
  wb:key({ code = "C", alt = true })
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.context, 2, "Alt+C 折叠上下文：context 重画")
  eq(st.regions.main, 4, "Alt+C 折叠上下文：main 重画（宽度变了）")
  eq(st.regions.composer, 2, "Alt+C 不动 composer")

  -- 尺寸变化 -> 唯一合法的整屏重画
  wb:setSize(800, 600)
  gc.width, gc.height = 800, 600
  wb:paint(gc)
  st = wb:paintStats()
  eq(st.regions.titlebar, 2, "尺寸变化 -> titlebar 也重画")
  eq(st.regions.rail, 2, "尺寸变化 -> rail 也重画")
  eq(st.regions.context, 3, "尺寸变化 -> context 也重画")
  eq(st.regions.main, 5, "尺寸变化 -> main 也重画")
  eq(st.regions.composer, 3, "尺寸变化 -> composer 也重画")
end

----------------------------------------------------------------------
-- 5. 键盘全流程（ui §6）
----------------------------------------------------------------------

print("== workbench: 键盘 ==")
do
  local wb = newWB({})
  local gc = fakeGC(900, 620)
  wb:paint(gc)

  wb.state.focus = "main"
  ok(wb:key({ code = "/" }), "/ 被壳吃掉")
  eq(wb.state.focus, "composer", "/ 把焦点给 composer")
  eq(wb:getInput(), "/", "/ 顺便插入 / 唤起补全")
  ok(wb.completionOpen, "/ 打开补全")

  ok(wb:key({ code = "K", ctrl = true }), "Ctrl+K 被吃掉")
  ok(wb.paletteOpen, "Ctrl+K 打开命令面板")

  ok(wb:key({ code = "Escape" }), "Esc 关面板") -- 补全已先被关掉？见下
  -- 上面一次 Esc 关的是补全（先开着的），再按一次才关面板
  ok(wb.paletteOpen or wb.completionOpen == false, "Esc 按层级逐级关闭")

  -- 干净状态下的三级 Esc
  local wb2 = newWB({ now = function() return 100 end })
  wb2:setInput("/")
  wb2.completionOpen = true
  eq(wb2:escape(), "completion", "Esc 第一级：关补全")
  wb2:openPalette()
  eq(wb2:escape(), "popup", "Esc 第二级：关弹层")
  wb2:setBusy(true)
  eq(wb2:escape(), "armed", "Esc 第三级：先武装（2 秒内再按才真中断）")
  eq(wb2:escape(), "interrupt", "2 秒内再按一次：真中断")
  eq(wb2.state.busy, false, "中断后 busy 归位")

  -- 2 秒过期后不中断
  local t = 0
  local wb3 = newWB({ now = function() return t end })
  wb3:setBusy(true)
  eq(wb3:escape(), "armed", "第一次 Esc 武装")
  t = 5
  eq(wb3:escape(), "armed", "超过 2 秒不再中断，只重新武装")
  eq(wb3.state.busy, true, "超时后仍然 busy")

  -- Alt+1..6 切视图
  local wb4 = newWB({})
  local ids = {}
  for i, s in ipairs(wb4.specs) do ids[i] = s.id end
  ok(#wb4.specs >= 6, "至少 6 个视图用于 Alt+1..6", #wb4.specs)
  local allOk = true
  for i = 1, 6 do
    wb4:key({ code = tostring(i), alt = true })
    if wb4.viewId ~= ids[i] then allOk = false end
  end
  ok(allOk, "Alt+1..6 依次切到左轨第 1..6 个视图")
  eq(ids[1], "console", "左轨第一项是会话")
  eq(ids[2], "canvas", "左轨第二项是画布")
  eq(ids[5], "packs", "左轨第五项是扩展")

  -- Alt+C
  local wb5 = newWB({})
  local before = wb5:layout()
  eq(before.collapsed, false, "900 宽默认展开上下文")
  wb5:key({ code = "C", alt = true })
  eq(wb5:layout().collapsed, true, "Alt+C 折叠上下文")
  wb5:key({ code = "C", alt = true })
  eq(wb5:layout().collapsed, false, "再按 Alt+C 展开")

  -- Tab 轮转焦点
  local order = { "rail", "main", "context", "composer" }
  wb5.state.focus = "rail"
  local seen = {}
  for i = 1, 4 do wb5:key({ code = "Tab" }); seen[#seen + 1] = wb5.state.focus end
  eq(table.concat(seen, ","), "main,context,composer,rail", "Tab 在 左轨->主视图->上下文->composer 间轮转")
end

----------------------------------------------------------------------
-- 6. 四形态（D4：一个都不能丢）
----------------------------------------------------------------------

print("== workbench: 四形态 ==")
do
  local wb = newWB({})
  eq(wb.mode, "panel", "默认形态 = 面板")
  local L = wb:layout()
  eq(L.rail.w, 56, "面板形态有左轨")

  wb:setMode("bar_bottom")
  L = wb:layout()
  eq(L.bar, true, "底边栏形态")
  eq(L.titlebar.h, 0, "底边栏没有 titlebar")
  eq(L.rail.w, 0, "底边栏隐藏左轨")
  eq(L.context, nil, "底边栏隐藏上下文")
  eq(L.main.w, 900, "底边栏主视图占满宽度")
  eq(L.composer.h, 40, "底边栏保留 composer")

  eq(L.compressed, true, "底边栏把主视图压成单行")

  wb:setMode("bar_side")
  L = wb:layout()
  eq(L.bar, true, "侧边栏形态")
  eq(L.main.w, 900, "侧边栏主视图占满宽度")
  eq(L.compressed, false, "侧边栏不压成单行（窄而高，日志照常多行）")

  -- 两种栏形态都要真能画出来（不能只在 layout 上正确）
  local wbBar = newWB({})
  wbBar:log("last line output", "info")
  wbBar:setMode("bar_bottom")
  local gcBar = fakeGC(900, 60)
  local okBar = pcall(function() wbBar:paint(gcBar) end)
  ok(okBar, "底边栏形态能画（不崩）")
  ok(drewContaining(gcBar, "last line output"), "底边栏显示最后一行输出")
  ok(drewContaining(gcBar, "connected"), "底边栏显示状态")

  wbBar:setMode("bar_side")
  local gcSide = fakeGC(260, 420)
  local okSide = pcall(function() wbBar:paint(gcSide) end)
  ok(okSide, "侧边栏形态能画（不崩）")

  wb:setMode("small")
  L = wb:layout()
  eq(L.small, true, "小窗形态")
  eq(L.rail, nil, "小窗没有左轨")
  local gc = fakeGC(360, 56)
  ok(pcall(function() wb:paint(gc) end), "小窗形态能画（不崩）")

  -- /bar 循环：panel -> bar_bottom -> bar_side -> small -> panel
  wb:setMode("panel")
  eq(wb:cycleMode(), "bar_bottom", "/bar 第一次循环到 底边栏")
  eq(wb:cycleMode(), "bar_side", "/bar 第二次循环到 侧边栏")
  eq(wb:cycleMode(), "small", "/bar 第三次循环到 小窗")
  eq(wb:cycleMode(), "panel", "/bar 第四次循环回 面板")

  eq(wb:setMode("nonsense"), "panel", "未知形态被拒绝，保持原形态")
end

----------------------------------------------------------------------
-- 7. 空状态 / 断连态（ui §5）
----------------------------------------------------------------------

print("== 空状态与断连态 ==")
do
  local wb = newWB({})
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "Say what you want changed"), "会话空状态给出可照抄的一句话")
  ok(drewContaining(gc, "make this layer"), "会话空状态给三个可点示例（示例 1）")
  ok(drewContaining(gc, "merge down to 64"), "会话空状态给三个可点示例（示例 2）")
  ok(drewContaining(gc, "outline the subject"), "会话空状态给三个可点示例（示例 3）")
  ok(not drewContaining(gc, "No data"), "空状态不是「暂无数据」")
  ok(not drewContaining(gc, "暂无数据"), "空状态没有回落到「暂无数据」中文版")

  local cv = wb:currentView()
  local exHits = 0
  for _, h in ipairs(cv.hits or {}) do if h.kind == "example" then exHits = exHits + 1 end end
  eq(exHits, 3, "三个示例都是可点命中框")

  wb:setConnected(false, { reason = "bridge not connected", cmd = "cd bridge; node src/server.mjs" })
  gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "bridge not connected"), "断连：顶部红条写出原因")
  ok(drewContaining(gc, "cd bridge; node src/server.mjs"), "断连：给出一条可复制的起桥命令")
  ok(drewContaining(gc, "Retry"), "断连：给重试按钮")
  ok(wb.retryHit ~= nil, "断连：重试按钮有命中框")
  local errBand = false
  for _, c in ipairs(wb.kit.calls) do
    if c.op == "fill" and c.tone == "err" and c.w <= 4 then errBand = true end
  end
  ok(errBand, "断连：红条用 err 色（状态永远可见）")
  eq(wb:mouse("click", wb.retryHit.x + 2, wb.retryHit.y + 2), "retry", "点重试回到已连接")
  eq(wb.state.connected, true, "重试后状态回到已连接")
end

print("== 扩展页空状态 ==")
do
  local wb = newWB({ viewId = "packs" })
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "No custom capability packs yet"), "扩展空状态说明现状")
  ok(drewContaining(gc, "gaps.md"), "扩展空状态指向 gaps.md（让它知道缺什么）")
  ok(drewContaining(gc, "Propose"), "扩展空状态给「让它提议」按钮")
end

----------------------------------------------------------------------
-- 8. 画布页：算子名单只来自 registry
----------------------------------------------------------------------

print("== 画布页：算子动态来自 registry ==")
do
  local reg = fakeRegistry()
  reg:define("op", { name = "flip_h", label = "水平翻转", params = { { name = "axis" } } })
  reg:define("op", { name = "dither", label = "抖动", params = {} })
  local wb = newWB({ registry = reg, viewId = "canvas" })
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "水平翻转"), "画布页列出了 registry 里的算子 (1)")
  ok(drewContaining(gc, "抖动"), "画布页列出了 registry 里的算子 (2)")
  ok(not drewContaining(gc, "replace_color"), "没有硬编码老算子名")

  -- 热装一个新算子：再画一帧就该出现
  reg:define("op", { name = "posterize", label = "海报化", params = {} })
  wb:invalidate("main")
  gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "海报化"), "新算子注册后立刻出现在列表里（无需改内核）")

  -- 一个算子都没有时是空状态，不是空列表
  local wbEmpty = newWB({ registry = fakeRegistry(), viewId = "canvas" })
  local gc2 = fakeGC(900, 620)
  wbEmpty:paint(gc2)
  ok(drewContaining(gc2, "No operators are registered"), "空算子表给空状态文案")
end

print("== 扩展页：失败包标红 + 健康度 ==")
do
  local ledger = fakeLedger(
    { { id = "sharp", name = "锐化与对比", enabled = true } },
    { sharp = { calls = 12, fails = 3, lastErr = "attempt to index a nil value", msAvg = 4.5 } }
  )
  local wb = newWB({ ledger = ledger, viewId = "packs" })
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  ok(drewContaining(gc, "锐化与对比"), "扩展页列出已装包")
  ok(drewContaining(gc, "attempt to index a nil value"), "失败包写出失败原因")
  ok(drewContaining(gc, "12"), "健康度显示调用次数")
  ok(drewContaining(gc, "回滚") or drewContaining(gc, "Rollback"), "有回滚按钮")
  local hasErr = false
  for _, c in ipairs(wb.kit.calls) do
    if c.tone == "err" then hasErr = true end
  end
  ok(hasErr, "失败包用 err 色（不是只用文字说）")
end

----------------------------------------------------------------------
-- 9. golden layout（两个尺寸，只比 rect 与调用名）
----------------------------------------------------------------------

local GOLDEN = {
  { name = "900x620", w = 900, h = 620, file = ROOT .. "/tests/lua/kit_golden_900x620.txt" },
  { name = "640x420", w = 640, h = 420, file = ROOT .. "/tests/lua/kit_golden_640x420.txt" },
}

local function goldenFixture(w, h)
  local reg = fakeRegistry()
  reg:define("op", { name = "sharpen", label = "Sharpen", params = { { name = "amount" } } })
  reg:define("op", { name = "contrast", label = "Contrast", params = {} })
  reg:define("command", { id = "snapshot", title = "Snapshot", keys = "s" })
  local wb = newWB({ registry = reg, width = w, height = h })
  wb:setSize(w, h)
  wb:setDoc({ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 })
  wb:log("make this layer's red darker", "user", { ts = 1750000000000 })
  wb:log("done -- applied on layer 2.", "ai")
  wb:log("replace_color  256 px", "tool")
  wb:log("nothing went wrong.", "info")
  return wb
end

local function serialize(kit)
  local out = {}
  for _, c in ipairs(kit.calls) do
    out[#out + 1] = string.format("%s|%s|%d,%d,%d,%d", c.region, c.op, c.x, c.y, c.w, c.h)
  end
  return out
end

local function readAll(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local data = f:read("a")
  f:close()
  return data
end

local function writeAll(path, lines)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(table.concat(lines, "\n"))
  f:write("\n")
  f:close()
  return true
end

print("== golden layout ==")
for _, g in ipairs(GOLDEN) do
  local wb = goldenFixture(g.w, g.h)
  local gc = fakeGC(g.w, g.h)
  wb:paint(gc)
  local lines = serialize(wb.kit)
  ok(#lines > 40, g.name .. "：一帧产生足量绘制调用", #lines)
  local badUtf8 = nil
  for _, txt in ipairs(gc.texts) do
    if utf8.len(txt.text) == nil then badUtf8 = txt.text; break end
  end
  ok(badUtf8 == nil, g.name .. "：整帧没有任何非法 UTF-8 文本（fillText 会被它崩掉）", badUtf8)

  -- 假粗不变式：偏移双画只允许出现在纯 ASCII 上，否则中文会糊
  local badBold = nil
  for _, c in ipairs(wb.kit.calls) do
    if c.op == "text" and c.double and not kitMod.isAsciiText(c.text or "") then badBold = c.text; break end
  end
  ok(badBold == nil, g.name .. "：整帧没有对非 ASCII 文本做偏移双画（假粗）", badBold)

  -- ASE_GOLDEN_REGEN=1 重录（改布局时用，改完必须再跑一遍不带它确认能逐条相等）
  -- 注意别写成 "x and nil or readAll()"：真分支是 nil 时 and/or 会走到 or（Lua 的经典坑）
  local want = readAll(g.file)
  if os.getenv("ASE_GOLDEN_REGEN") == "1" then want = nil end
  if want == nil then
    local wrote = writeAll(g.file, lines)
    ok(wrote, g.name .. "：golden 首次自举写出 " .. g.file)
    print("       (golden 已生成：" .. g.file .. "，" .. #lines .. " 行)")
  else
    local wantLines = {}
    for line in want:gmatch("[^\r\n]+") do wantLines[#wantLines + 1] = line end
    local same = (#wantLines == #lines)
    local firstDiff = nil
    if same then
      for i = 1, #lines do
        if wantLines[i] ~= lines[i] then same = false; firstDiff = i; break end
      end
    else
      firstDiff = math.min(#wantLines, #lines) + 1
    end
    ok(same, g.name .. "：绘制调用序列与 golden 逐条相等（" .. #lines .. " 条）",
       firstDiff and string.format("第 %d 条起不同：want=%s got=%s",
                                   firstDiff, tostring(wantLines[firstDiff]), tostring(lines[firstDiff])))
    if not same then
      writeAll(ROOT .. "/tests/lua/kit_test.actual.txt", lines)
      print("       实际序列已写到 tests/lua/kit_test.actual.txt")
    end
  end
end

----------------------------------------------------------------------
-- 10. 预算（ui §7 五项，宽松但存在）
----------------------------------------------------------------------

print("== 预算（ui §7）==")
do
  -- 面板首屏（构建 + 一帧）< 150ms
  local t0 = os.clock()
  local wb = newWB({ width = 900, height = 620 })
  local gc = fakeGC(900, 620)
  wb:paint(gc)
  local firstMs = (os.clock() - t0) * 1000
  ok(firstMs < 150, string.format("面板首屏 %.1fms < 150ms", firstMs), firstMs)

  -- 900x620 全屏重绘 < 8ms（取 5 次最小值：单次被调度打断不该判红）
  local best = math.huge
  for _ = 1, 5 do
    wb:invalidate()
    local t = os.clock()
    wb:paint(gc)
    local ms = (os.clock() - t) * 1000
    if ms < best then best = ms end
  end
  ok(best < 8, string.format("900x620 全屏重绘 %.3fms < 8ms", best), best)

  -- 单次输入回显 < 30ms（只 dirty composer）
  local evBest = math.huge
  for _ = 1, 5 do
    wb:setInput("make the red darker")
    local t = os.clock()
    wb:paint(gc)
    local ms = (os.clock() - t) * 1000
    if ms < evBest then evBest = ms end
  end
  ok(evBest < 30, string.format("输入回显 %.3fms < 30ms", evBest), evBest)
  ok(evBest < best, "输入回显比全屏重绘便宜（脏区分级真的生效）", string.format("%.3f vs %.3f", evBest, best))

  -- 滚动一屏 < 16ms
  wb:setView("console")
  local scBest = math.huge
  for _ = 1, 5 do
    wb:wheel(400, 300, 1)
    local t = os.clock()
    wb:paint(gc)
    local ms = (os.clock() - t) * 1000
    if ms < scBest then scBest = ms end
  end
  ok(scBest < 16, string.format("滚动一屏 %.3fms < 16ms", scBest), scBest)

  -- 每次 ui tick 的 Lua 分配 < 64KB
  collectgarbage("collect")
  local before = collectgarbage("count")
  wb:setInput("a")
  wb:paint(gc)
  local after = collectgarbage("count")
  local kb = after - before
  ok(kb < 64, string.format("单次 tick Lua 分配 %.1fKB < 64KB", kb), kb)
end

----------------------------------------------------------------------
-- 11. 入口签名（T1 接线的契约）
----------------------------------------------------------------------

print("== 入口签名 ==")
do
  local wb = workbench.new({})
  eq(type(wb.mount), "function", "workbench.new -> wb:mount(kernel, agent)")
  eq(type(wb.setMode), "function", "wb:setMode(mode)")
  eq(type(wb.destroy), "function", "wb:destroy()")
  eq(type(wb.paint), "function", "wb:paint(gc)（壳自己的入口，供 dlg canvas onpaint）")
  eq(type(wb.key), "function", "wb:key(ev)")
  eq(type(wb.invalidate), "function", "wb:invalidate(region)")
  wb:destroy()
  eq(wb.view, nil, "destroy 清掉视图实例")
end

----------------------------------------------------------------------
-- 12. 七个视图都能挂载、都能在两个尺寸下画出来
----------------------------------------------------------------------

print("== 视图挂载与渲染 ==")
do
  local wb = newWB({})
  local ids = {}
  for i, s in ipairs(wb.specs) do ids[i] = s.id end
  eq(#ids, 7, "内置 7 个视图都进了左轨")

  local mountOk = true
  local brokenId = nil
  for _, id in ipairs(ids) do
    wb:setView(id)
    local v = wb:currentView()
    if not v or v.broken then mountOk = false; brokenId = id end
  end
  ok(mountOk, "7 个视图都能 mount（没有 placeholder/broken）", brokenId)

  local renderOk = true
  local failedId, failedErr = nil, nil
  for _, size in ipairs({ { 900, 620 }, { 640, 420 } }) do
    for _, id in ipairs(ids) do
      wb:setView(id)
      wb:setSize(size[1], size[2])
      local gc = fakeGC(size[1], size[2])
      wb:paint(gc)
      if wb.lastViewError then
        renderOk = false
        failedId = id .. "@" .. size[1]
        failedErr = wb.lastViewError
      end
    end
  end
  ok(renderOk, "7 个视图在 900x620 与 640x420 下都能渲染，无异常", tostring(failedId) .. " " .. tostring(failedErr))

  -- registry 是唯一视图权威：注册一个同名 view，registry 胜
  local reg = fakeRegistry()
  reg:define("view", { id = "console", title = "AUTHORITATIVE", icon = "☆", order = 5,
                       mount = function() return { id = "console", render = function() end, title = function() return "authoritative" end } end })
  local wb2 = newWB({ registry = reg })
  local spec = wb2:_specOf("console")
  eq(spec and spec.title, "AUTHORITATIVE", "同 id 时 registry 的 view 规格胜出")
  eq(wb2:currentView().id, "console", "registry 规格被真正挂载")
  ok(wb2:currentView().title() == "authoritative", "挂载的确实是 registry 给的视图")

  -- registry 挂不起来时回落兜底表，而不是黑屏
  local reg2 = fakeRegistry()
  reg2:define("view", { id = "console", title = "BROKEN", order = 5,
                        mount = function() error("boom") end })
  local wb3 = newWB({ registry = reg2 })
  local v3 = wb3:currentView()
  ok(v3 ~= nil and not v3.broken, "registry 的 mount 抛错时回落内置实现，不黑屏")
  ok(wb3.viewErrors == nil or wb3.viewErrors.console == nil, "回落成功时不记错误")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
