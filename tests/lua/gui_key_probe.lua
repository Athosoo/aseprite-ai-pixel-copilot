-- tests/lua/gui_key_probe.lua
--
-- 验证"连续退格"：程序化预填输入，然后把退格【用真键盘】发进来
-- （外部 tests/type_probe.ps1 用 SendKeys 发 {BACKSPACE}）。
--
-- 为什么必须用真键盘：哨兵机制下的光标位置只有真实按键路径才暴露 ——
-- 探针里 dlg:modify{ text = ... } 是直接改文本，绕过了 caret，
-- 所以"只能删一个字"的 bug 在纯 Lua 探针里根本复现不出来。

local EXT = [[D:\PraticleTool\Aseprite-AI\extension]]
package.path = package.path .. ";" .. EXT .. [[\?.lua]]

local ok, err = pcall(function()
  local agentModule = require("lib.agent")

  app.activeSprite = Sprite(16, 16, ColorMode.RGB)

  local agent = agentModule.new{ port = 8777, bridgeHint = "(keyprobe)" }
  agent:open()
  local p = agent.panel

  p:log("KEYPROBE: 预填输入 = abc，接下来外部会发 3 次真退格", "tool")
  p:log("KEYPROBE: 期望 —— 输入被删空；旧 bug 只会删掉最后 1 个（剩 ab）", "tool")
  p:fillInput("abc")
end)

if not ok then
  app.alert("key probe error: " .. tostring(err))
end
