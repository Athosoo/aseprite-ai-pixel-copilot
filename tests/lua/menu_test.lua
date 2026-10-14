-- tests/lua/menu_test.lua
--
-- 无头（-b）单元测试：语言解析、内建命令、命令表打印与排版、输入模型（哨兵）、
-- 队列/历史/面板路由。像素层面的东西见 tests/run_gui_visual.sh --term。
--
-- 跑法：  "<你的 Aseprite>/aseprite.exe" -b --script tests/lua/menu_test.lua

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end   -- 从仓库根跑即可
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

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

print("== syntax check ==")
for _, f in ipairs({ "main.lua", "lib/util.lua", "lib/i18n.lua", "lib/menu.lua",
                     "lib/miniwindow.lua", "lib/panel.lua", "lib/agent.lua",
                     "lib/settings.lua", "lib/ws.lua", "lib/ops.lua", "lib/versions.lua" }) do
  local chunk, err = loadfile(EXT .. "\\" .. f:gsub("/", "\\"))
  ok(chunk ~= nil, f .. (chunk and "" or ("  <- " .. tostring(err))))
end

local i18n = require("lib.i18n")
local menu = require("lib.menu")
local panel = require("lib.panel")

print("== i18n: 语言解析（默认中文）==")
do
  i18n._resetLang()
  ok(i18n.resolve("zh_hans", "Windows 10 (English)") == "zh_hans", "首选 zh_hans -> 中文")
  i18n._resetLang()
  ok(i18n.resolve("en", "Windows 11 中文版") == "zh_hans", "首选 en(默认) + 中文系统 -> 中文")
  i18n._resetLang()
  ok(i18n.resolve("en", "Windows 11 English") == "en", "识别到英文系统 -> 英文")
  i18n._resetLang()
  ok(i18n.resolve("en", "Windows 11") == "zh_hans", "读不到系统语言 -> 默认中文")
  i18n._resetLang()
  ok(i18n.resolve("en", "C.UTF-8") == "zh_hans", "Git-Bash 的 C.UTF-8 不带偏判断")
  i18n._resetLang()
  ok(i18n.resolve(nil, "") == "zh_hans", "什么都没有 -> 默认中文")
end

print("== i18n: 双语文案 ==")
do
  i18n._resetLang(); i18n.resolve("en", "English")
  ok(i18n.lang() == "en", "切到英文")
  ok(i18n.t("fixRun") == "Start", "英文矫正按钮，实际 " .. tostring(i18n.t("fixRun")))
  ok(i18n.miniLabel("versions") == "Versions", "英文小面板标签")

  i18n._resetLang(); i18n.resolve("zh_hans", "")
  ok(i18n.lang() == "zh_hans", "切回中文")
  ok(i18n.t("fixRun") == "开始矫正", "中文矫正按钮，实际 " .. tostring(i18n.t("fixRun")))
  ok(i18n.miniLabel("fix") == "矫正图片", "中文小面板标签")
  ok(i18n.helpText():find("示例指令") ~= nil, "中文帮助")
  ok(i18n.promptMark() == "AI >", "提示符（ASCII，字形一定在）")
  ok(i18n.statusText("ready") == "就绪", "桥状态翻译")
end

print("== i18n: 内建命令 ==")
do
  local cases = {
    { "菜单", "menu" }, { "menu", "menu" }, { "[MENU]", "menu" },
    { "清屏", "clear" }, { "cls", "clear" }, { "帮助", "help" }, { "?", "help" },
    { "设置", "settings" }, { "快照", "snapshot" }, { "备份", "snapshot" },
    { "回滚", "rollback" }, { "版本", "versions" }, { "矫正", "fix" },
    { "选图", "upload" }, { "退出", "@exit" }, { "exit", "@exit" },
  }
  for _, c in ipairs(cases) do
    ok(i18n.builtinAction(c[1]) == c[2], string.format("「%s」-> %s", c[1], c[2]))
  end
  ok(i18n.builtinAction("把背景的红色换成蓝色") == nil, "普通指令不是内建命令")
end

print("== menu: 表行排版 ==")
do
  local rows = i18n.menuCommands()
  ok(#rows >= 9, "命令数 >= 9: " .. #rows)
  local lines = menu.tableLines(rows)
  ok(#lines == #rows, "每行一条输出")
  ok(lines[1].index == 1 and lines[1].id == "snapshot", "第 1 行是 snapshot")
  ok(lines[1].text:find("1:S") ~= nil, "第 1 行带编号和键位：" .. lines[1].text)
  ok(lines[1].text:find(i18n.promptMark(), 1, true) == nil, "表行里没有提示符")
  -- 列对齐：编号:键位 那列宽度固定；label 用 padRight 补到同一列宽
  ok(menu.columns(" 1:S  ") == menu.columns(" 9:H  "), "编号/键位列宽度固定")
  ok(menu.columns(menu.padRight("短", 12)) == 12, "padRight 补到目标列宽")
  ok(menu.columns(menu.padRight("已经很长了", 4)) == 10, "超长不截断（不撑爆）")
  ok(#lines[1].text > 0 and #lines[9].text > 0, "首尾两行都有内容")
  ok(menu.columns("abc") == 3 and menu.columns("菜单") == 4, "列宽：ASCII 1 / CJK 2")
end

print("== menu: 输入解析 ==")
do
  local rows = i18n.menuCommands()
  ok(menu.resolveInput(rows, "1") == 1, "1 -> 第 1 项")
  ok(menu.resolveInput(rows, " 9 ") == 9, "带空格 9 -> 第 9 项")
  ok(menu.resolveInput(rows, "99") == nil, "越界不给")
  ok(menu.resolveInput(rows, "v") == 3, "键位 v -> 第 3 项（版本栈）")
  ok(menu.resolveInput(rows, "V") == 3, "大写键位也行")
  ok(menu.resolveInput(rows, "把红色换成蓝色") == nil, "普通指令不是选单")
end

print("== panel: 输入模型（哨兵 + 增删）==")
do
  local fired = {}
  local p = panel.new{
    menuCommands = function() return i18n.menuCommands() end,
    onAction = function(id) fired[#fired + 1] = id end,
    onSend   = function(t) fired[#fired + 1] = "send:" .. t end,
  }
  ok(p:inputValue() == "", "初始输入为空")
  p:fillInput("把红色换成蓝色")
  ok(p:inputValue() == "把红色换成蓝色", "fillInput 往返不丢字")
  p:fillInput("")
  ok(p:inputValue() == "", "清空")

  -- 模拟"真人打字"：把字符插进 entry，再触发 onchange
  p.dlg = nil                                  -- 无头：没有 dlg，直接走内部逻辑
  p.input = ""
  -- 插入
  p.input = p.input .. "你好"
  ok(p:inputValue() == "你好", "插入中文")
  p.input = p.input .. "abc"
  ok(p:inputValue() == "你好abc", "插入 ASCII")
  -- 退格（按 UTF-8 字符边界）
  p:_inputBackspace()
  ok(p:inputValue() == "你好ab", "退格删 ASCII")
  p:_inputBackspace()
  p:_inputBackspace()
  ok(p:inputValue() == "你好", "连续退格")
  p:_inputBackspace()
  ok(p:inputValue() == "你", "退格删中文（不切碎多字节）")
  p:_inputBackspace()
  ok(p:inputValue() == "", "退到空")
  p:_inputBackspace()
  ok(p:inputValue() == "", "空的时候退格不炸")
end

print("== panel: 命令表打印 + 编号执行 + 自动重打 ==")
do
  local fired = {}
  local p = panel.new{
    menuCommands = function() return i18n.menuCommands() end,
    onAction = function(id) fired[#fired + 1] = id end,
    onSend   = function(t) fired[#fired + 1] = "send:" .. t end,
  }
  p:openMenu()
  ok(p:menuIsOpen() == true, "openMenu 打开")
  ok(p.menuRows and #p.menuRows >= 9, "行数据就绪")

  -- 表头 + 每行都进了缓冲，且带 menuIndex（供悬浮/点击）
  local menuLines = 0
  for _, l in ipairs(p.lines) do
    if l.menuIndex then menuLines = menuLines + 1 end
  end
  ok(menuLines == #p.menuRows, "打印了 " .. menuLines .. " 行命令表（应等于 " .. #p.menuRows .. "）")

  local before = #p.lines
  fired = {}
  p:fillInput("1")
  p:_submit()
  ok(fired[1] == "snapshot", "编号 1 -> snapshot，实际 " .. tostring(fired[1]))
  ok(#p.lines > before, "执行后自动重打了一份（行数 " .. before .. " -> " .. #p.lines .. "）")
  ok(p:menuIsOpen() == true, "重打后菜单仍然开着")

  -- 键位执行
  fired = {}
  p:fillInput("h")
  p:_submit()
  ok(#fired == 0, "键位 h = 帮助，不发给 AI")

  -- x 关闭
  p:fillInput("x")
  p:_submit()
  ok(p:menuIsOpen() == false, "x 关闭命令表")

  -- 关掉之后普通指令照发
  fired = {}
  p:fillInput("把背景的红色换成蓝色")
  p:_submit()
  ok(fired[1] == "send:把背景的红色换成蓝色", "关闭后普通指令发给 AI")
end

print("== panel: 历史 ==")
do
  local p = panel.new{}
  p.history = { "第一条", "第二条" }
  p.historyPos = 0
  p.inHistory = false
  p.draft = ""
  p:fillInput("半截草稿")
  p:_onKeyDown({ code = "ArrowUp", stopPropagation = function() end })
  ok(p:inputValue() == "第二条", "↑ 第一次 -> 最新一条，实际「" .. p:inputValue() .. "」")
  p:_onKeyDown({ code = "ArrowUp", stopPropagation = function() end })
  ok(p:inputValue() == "第一条", "↑ 第二次 -> 更早一条")
  p:_onKeyDown({ code = "ArrowDown", stopPropagation = function() end })
  ok(p:inputValue() == "第二条", "↓ -> 回到较新一条")
  p:_onKeyDown({ code = "ArrowDown", stopPropagation = function() end })
  ok(p:inputValue() == "半截草稿", "↓ 到底 -> 把草稿还回来")
end

print("== panel: 命中测试（悬浮/点击） ==")
do
  local p = panel.new{}
  p.hitRows = {
    { x = 0, y = 100, w = 880, h = 24, index = 1 },
    { x = 0, y = 124, w = 880, h = 24, index = 2 },
  }
  ok(p:_menuIndexAt(400, 110) == 1, "命中第 1 行")
  ok(p:_menuIndexAt(400, 130) == 2, "命中第 2 行")
  ok(p:_menuIndexAt(400, 300) == nil, "空白处不命中")
end

print("== panel: 矫正队列 ==")
do
  local started = nil
  local p = panel.new{ onFixRun = function(q) started = q end }
  ok(p:fixQueueSize() == 0, "初始队列为空")
  p:addFixFile("D:/a/one.png")
  p:addFixFile("D:/a/two.png")
  p:addFixFile("D:/a/one.png")           -- 重复
  ok(p:fixQueueSize() == 2, "去重后 2 张，实际 " .. p:fixQueueSize())
  p:_fixStart()
  ok(type(started) == "table" and #started == 2 and started[2] == "D:/a/two.png", "开始矫正把队列交出去")
  ok(p:fixQueueSize() == 0, "开始后队列清空")
end

print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then
  app.alert("menu_test: " .. fail .. " FAILED")
end
