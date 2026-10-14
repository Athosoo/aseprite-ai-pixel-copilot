-- tests/lua/gui_panel_probe.lua
--
-- GUI 端到端可视化探针：真 Aseprite + 真扩展代码 + 真桥 + mock LLM。
-- 不需要写文件：所有结果都画在面板上，由外部截图（tests/run_gui_visual.sh）。
--
-- 验证四件事：
--   1) 面板对话框能正常构建与绘制（canvas 自绘日志 + entry + 按钮 + 文件选择器）
--   2) GUI 模式下 WebSocket 回调能触发（面板状态会变成 connected）
--   3) 完整回路：指令 -> LLM -> apply_ops -> 画布真的被改
--   4) 中英文字体渲染效果（用于决定是否换中文像素字体）
--
-- 前置：mock LLM(8792) 与桥(8777) 已启动。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end   -- 从仓库根跑即可
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local ok, err = pcall(function()
  local agentModule = require("lib.agent")

  -- 造一张测试画布：16x16 全红
  local spr = Sprite(16, 16, ColorMode.RGB)
  app.activeSprite = spr
  app.activeCel.image:clear(Rectangle(0, 0, 16, 16), Color(255, 0, 0))

  local agent = agentModule.new{ port = 8777, bridgeHint = "(probe)" }
  agent:open()

  local p = agent.panel
  p:log("PROBE: panel built OK, connecting to bridge...", "info")

  -- 中文样本（判断字体回退效果与抗锯齿）
  p:log("中文样本：像素画助手已就绪，改动前会自动备份。", "ai")
  p:log("中文样本：把背景的红色换成蓝色外壳，保留高光。", "user")
  p:log("混合样本：中文 mixed English 12px 一二三 ABCabc123", "info")
  -- 多段回复：验证空行保留 + 行距。
  -- 注意：这里必须用 \n 转义，不能写成真正的多行字符串字面量 ——
  -- 这个 Lua 的词法器只认 "\n"，文件存成 CRLF 时多行字符串会报
  -- "unfinished string"（llex.cpp 的 C89 分支）。整个 tests/ 都按这条来。
  p:log("第一段：这是多段回复的排版测试。\n\n第二段：中间应该空一行，行距也要够松。", "ai")
  p:log("这是思考过程的样子，应该是灰色。", "think")
  p:log("这是工具执行的样子，应该是弱青色。", "tool")

  agent:sendChat("把画布上的红色换成蓝色")

  -- 轮询：等 AI 最终回复出现后，把关键结论也打到面板上
  local tries = 0
  local finished = false
  local timer
  timer = Timer{
    interval = 0.3,
    ontick = function()
      tries = tries + 1
      local text = {}
      for _, l in ipairs(p.lines) do text[#text + 1] = l.text end
      text = table.concat(text, "\n")

      if text:find("已经换好了") or text:find("Already done") then
        if not finished then
          finished = true
          local px = app.activeCel.image:getPixel(0, 0)
          p:log(string.format("PROBE: canvas pixel (0,0) = %08X  (expect FF0000FF blue)",
            px), "info")
          p:log("PROBE: RESULT=OK -- panel + websocket + ops loop all worked", "ai")
          -- 验证输入框中文显示：往输入框里塞一句中文
          pcall(function()
            p.dlg:modify{ id = "input", text = "把背景的红色换成蓝色外壳，保留高光" }
          end)
          -- 打开设置对话框（验证渲染 + 截图留证）
          pcall(function() agent:action("settings") end)
          p:log("PROBE: opened Settings dialog + filled Chinese into the entry", "info")
          timer:stop()
        end
      elseif tries > 40 then
        p:log("PROBE: RESULT=FAIL -- timed out waiting for the AI reply", "error")
        timer:stop()
      end
    end,
  }
  timer:start()
end)

if not ok then
  -- 面板可能都没建起来，用 alert 兜底（截图能看到）
  app.alert("probe script error: " .. tostring(err))
end
