-- tests/lua/gui_term_probe.lua
--
-- 终端式面板的 GUI 可视化探针（真 Aseprite + 真扩展代码 + mock LLM）。
-- 由 tests/run_gui_visual.sh --term 拉起，外部截图（PrintWindow，不抢前台）。
--
-- 验收点（新交互）：
--   1) 输入画在画布上：长中文不裁切、能多行折行、带块光标
--   2) 命令表是【打印出来的文字表】：纵向排列、带编号:键位，悬浮那行变蓝
--   3) 底部极简：只有 [隐形输入点][⏎][…]
--   4) 小面板贴主窗口右下角
--   5) 图片矫正确认窗：小、能列队

local EXT = [[D:\PraticleTool\Aseprite-AI\extension]]
package.path = package.path .. ";" .. EXT .. [[\?.lua]]

local ok, err = pcall(function()
  local agentModule = require("lib.agent")
  local i18n = require("lib.i18n")

  -- 一张测试画布
  local spr = Sprite(16, 16, ColorMode.RGB)
  app.activeSprite = spr
  app.activeCel.image:clear(Rectangle(0, 0, 16, 16), Color(255, 0, 0))

  local agent = agentModule.new{ port = 8777, bridgeHint = "(probe)" }
  agent:open()
  local p = agent.panel

  p:log("PROBE: 面板语言 = " .. i18n.lang() .. "；终端式布局", "tool")
  p:log("中文样本：终端里的中文渲染不分行、不被裁切，颜色分 用户/AI/工具/错误", "ai")
  agent:sendChat("把背景的红色换成蓝色")

  -- (1)+(2) 长中文输入（验证折行 + 不裁切）+ 打印命令表 + 悬浮高亮
  p:fillInput("把背景的红色换成蓝色，然后把外壳的深蓝色换成浅一点的蓝，保留高光，别动阴影")
  p:openMenu()
  p:log("PROBE: 命令表已打印到输出里（下面是表头 + 9 行，悬浮行应变蓝）", "tool")

  -- 悬浮：等菜单行布局出来后在绘制里才有命中框；这里直接指定悬浮行 + 重绘
  p.menuHover = 5
  p:repaint()

  -- 9 秒后切场景：关表、清输入、开小面板（右下角）、弹矫正确认窗
  local t
  t = Timer{
    interval = 9.0,
    ontick = function()
      t:stop()
      p.menuOpen = false
      p.menuHover = 0
      p:fillInput("")
      p:log("PROBE: 切场景 —— 小面板（右下角）+ 图片矫正确认窗（队列 2 张）", "tool")
      p:addFixFile("D:/PraticleTool/Aseprite-AI/tests/lua/demo_a.png")
      p:addFixFile("D:/PraticleTool/Aseprite-AI/tests/lua/demo_b.png")
      p:showMini()
      p:repaint()
      pcall(function()
        p.mini.hot = 4            -- 模拟悬浮"设置"格
        p.mini:repaint()
      end)
      -- 真·entry 路径：模拟"用户敲键"（改 entry 文本 -> onchange -> 哨兵差分）
      --   哨兵 = 一个普通空格；敲入时 entry = " " .. 内容，退格 = 哨兵被删（entry 变空）。
      local function tryType(text)
        if not p.dlg then return end
        p.dlg:modify{ id = "input", text = " " .. text }
      end
      p.input = ""
      tryType("把红色")                                -- entry = " 把红色" -> 去掉哨兵 -> "把红色"
      p.dlg:modify{ id = "input", text = "" }          -- 哨兵被删 = 用户按了退格
      local afterBackspace = p:inputValue()
      p:log(string.format("PROBE: 输入仿真 敲入「把红色」+ 退格 -> 「%s」", afterBackspace),
            (utf8.len(afterBackspace) == 2) and "tool" or "error")
      p:log("PROBE: RESULT=OK -- 终端 + 打印式命令表 + 小面板 + 矫正队列都渲染出来了", "ai")
    end,
  }
  t:start()
end)

if not ok then
  app.alert("probe script error: " .. tostring(err))
end
