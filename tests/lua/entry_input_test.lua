-- tests/lua/entry_input_test.lua -- 原生输入行的退格 / 中文上屏（哨兵差分）
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/entry_input_test.lua
--
-- 为什么要有这条：真机上"打了字删不掉"。哨兵方案里当文本被清空后，Entry 只把 caret
-- clamp 到 0（entry.cpp:506），caret 在 0 时再按退格**前面没有字符** → 不触发 onchange
-- → self.input 永远停在原处。旧面板靠"先 focus send 再 focus input"把 caret 顶到末尾。
--
-- 这里用一个**照着 Aseprite 行为建模**的假 Entry（caret + 文本 + 焦点舞），
-- 所以它能真的把这条 bug 复现出来，而不是只断言我们调了哪个函数。

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

----------------------------------------------------------------------
-- 假 Dialog：只建模 ui::Entry 的那几条行为
--   * setText 只把 caret 往下 clamp，不挪到末尾（entry.cpp:506）
--   * 焦点进入 Entry 时把 caret 放到末尾（entry.cpp:283-295，焦点舞的原理）
--   * 退格：caret > 0 才删，删完触发 onchange；caret == 0 什么都不发生（这是 bug 的入口）
----------------------------------------------------------------------

local function typedDialog()
  local d = { repaints = 0, modifies = 0, focusDances = 0, caret = 1, widgets = {}, data = {} }
  d.data.input = " "                      -- SENTINEL
  d._bounds = { x = 0, y = 0, w = 912, h = 531 }

  local function clampCaret()
    local n = utf8.len(d.data.input) or 0
    if d.caret > n then d.caret = n end
    if d.caret < 0 then d.caret = 0 end
  end

  -- 触发 onchange（模拟宿主在文本变化后回调脚本）
  local function fire()
    if d.widgets.input and d.widgets.input.onchange then d.widgets.input.onchange() end
  end

  function d:repaint() self.repaints = self.repaints + 1 end
  function d:canvas(spec) self.widgets.screen = spec end
  function d:entry(spec)
    self.widgets.input = spec
    self.data.input = spec.text
    self.caret = utf8.len(spec.text) or 0     -- 初始时焦点在末尾
  end
  function d:button(spec) self.widgets[spec.id] = spec end
  function d:newrow() end
  function d:samerow() end
  function d:show() end
  function d:close() end
  function d:modify(opts)
    self.modifies = self.modifies + 1
    if opts.id == "input" then
      if opts.text ~= nil then
        self.data.input = opts.text
        clampCaret()                            -- 关键：只 clamp，不挪到末尾
      end
      if opts.focus then
        if self._lastFocus ~= "input" then self.focusDances = self.focusDances + 1 end
        self._lastFocus = "input"
        self.caret = utf8.len(self.data.input) or 0   -- 焦点进入 → caret 到末尾
      end
    elseif opts.id == "send" then
      self._lastFocus = "send"
    elseif opts.id == "screen" then
      self._lastFocus = "screen"
    end
  end
  -- 模拟用户按键
  function d:typeChar(ch)
    local n = self.data.input:sub(1, 0)
    local before = self.data.input:sub(1, self.caret)
    local after = self.data.input:sub(self.caret + 1)
    self.data.input = before .. ch .. after
    self.caret = self.caret + (utf8.len(ch) or 1)
    fire()
  end
  function d:backspace()
    if self.caret <= 0 then return false end   -- 前面没字符 → 宿主不产生变化事件
    local before = self.data.input:sub(1, self.caret - 1)
    local after = self.data.input:sub(self.caret + 1)
    self.data.input = before .. after
    self.caret = self.caret - 1
    fire()
    return true
  end

  return setmetatable(d, {
    __index = function(_, k) if k == "bounds" then return d._bounds end return nil end,
    __newindex = function(t, k, v)
      if k == "bounds" then d._bounds = { x = v.x, y = v.y, w = v.width, h = v.height } else rawset(t, k, v) end
    end,
  })
end

local function freshWB()
  local wb = workbench.new({ width = 900, height = 620 })
  wb:mount(nil, { docName = function() return "001.ase" end })
  wb:setSize(900, 620)
  local dlg = typedDialog()
  wb:build(dlg)
  wb.shown = true
  wb:setInput("")
  wb:openInput()
  dlg.caret = utf8.len(dlg.data.input) or 0
  return wb, dlg
end

print("== 1. 打字：连续输入追加到末尾 ==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("a")
  dlg:typeChar("b")
  dlg:typeChar("c")
  eq(wb:getInput(), "abc", "连续打 abc → 输入是 abc")
  eq(dlg.data.input, workbench.SENTINEL, "entry 里永远只有一个哨兵（正文由 canvas 画）")
  eq(dlg.caret, 1, "打字后光标在哨兵后面")
end

print("== 2. 退格：能连续删（这就是真机上失效的那条）==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("a")
  dlg:typeChar("b")
  dlg:typeChar("c")
  eq(wb:getInput(), "abc", "先打 abc")
  dlg:backspace()
  eq(wb:getInput(), "ab", "退格一次 → ab")
  dlg:backspace()
  eq(wb:getInput(), "a", "再退一格 → a（真机 bug：这里停住不动）")
  dlg:backspace()
  eq(wb:getInput(), "", "第三次退格 → 空")
  ok(dlg.focusDances >= 3, "每次退格都做了焦点舞把光标顶到末尾", dlg.focusDances)
end

print("== 3. 中文上屏：多字节按字符追加/删除 ==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("换")
  eq(wb:getInput(), "换", "中文字符能进去（单个多字节字符不被切坏）")
  dlg:typeChar("色")
  eq(wb:getInput(), "换色", "第二个中文字符追加正确")
  dlg:backspace()
  eq(wb:getInput(), "换", "退格删掉一个**字符**（不是删一个字节）")
  ok(utf8.len(wb:getInput()) == 1, "剩下的是合法 UTF-8 的单字符")
  dlg:backspace()
  eq(wb:getInput(), "", "再退一格清空")
end

print("== 4. 混合：中文 + ASCII 交替 ==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("换")
  dlg:typeChar("a")
  dlg:typeChar("色")
  eq(wb:getInput(), "换a色", "中英混排追加顺序正确")
  dlg:backspace()
  dlg:backspace()
  eq(wb:getInput(), "换", "退两格回到「换」")
end

print("== 5. 提交后输入行收起，草稿清空 ==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("h")
  dlg:typeChar("i")
  wb:submit()
  eq(wb:getInput(), "", "提交后草稿清空")
  eq(wb.inputOpen, false, "提交后输入行收起")
  eq(dlg.widgets.input.visible, false, "entry 不可见")
end

print("== 6. 复位期间不会重复跑插入/退格逻辑（entrySyncing 挡住）==")
do
  local wb, dlg = freshWB()
  dlg:typeChar("x")
  local before = wb:getInput()
  -- 手动触发一次"复位产生的 onchange"：文本仍是哨兵 → 不该改动输入
  if dlg.widgets.input and dlg.widgets.input.onchange then dlg.widgets.input.onchange() end
  eq(wb:getInput(), before, "哨兵未变的 onchange 不改输入")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
