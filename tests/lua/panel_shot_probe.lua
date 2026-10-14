-- tests/lua/panel_shot_probe.lua
--
-- 打开面板并填满示例内容，然后【保持不退出】，供外部截图。
-- 用于视觉检查：面板布局、中英文字体渲染、颜色。
--
-- 跑法（见 tests/shot_panel.sh）：会临时关掉脚本运行确认框，截完图后由外部杀掉进程。

local EXT = "D:/PraticleTool/Aseprite-AI/extension"
local OUT = "D:/PraticleTool/Aseprite-AI/tests/lua/panel_shot_ready.txt"

package.path = package.path .. ";" .. EXT .. "/?.lua"

local ok, err = pcall(function()
  local panel = require("lib.panel")

  local p = panel.new{
    onSend = function() end,
    onAction = function() end,
    onUpload = function() end,
  }
  p:show()
  p:setStatus("connected  |  32x32  Layer 1")
  p:setHint("Try: replace #FF0000 with #2E86DE / outline with #1B1B1B")

  p:log("AI Pixel Copilot ready. Canvas edits are backed up first.", "info")
  p:log("> replace the background red with a blue shell colour", "user")
  p:log("I will swap every #E53935 pixel for #2E86DE and keep the alpha.", "ai")
  p:log("Auto-backed up v1 \"before: background to blue\"", "info")
  p:log("Applied 1 op(s) on layer Layer 1 -- replace_color: 184 px", "ai")
  p:log("Done. 184 pixels changed.", "ai")

  -- 中文渲染样本（用来判断字体回退效果与抗锯齿）
  p:log("中文测试：像素画助手已就绪，改动前会自动备份。", "ai")
  p:log("中文测试：把背景的红色换成蓝色外壳，并保留高光。", "user")
  p:log("中文小字：一二三四五六七八九十 甲乙丙丁 像素字体 ABCabc123", "info")
  p:log("中文混合 English mixed 中文 English 混合 12px", "info")
  p:log("error sample: ops failed, canvas untouched", "error")

  local f = io.open(OUT, "w")
  if f then
    f:write("ready\n")
    f:close()
  end
end)

if not ok then
  local f = io.open(OUT, "w")
  if f then
    f:write("error: " .. tostring(err) .. "\n")
    f:close()
  end
end
