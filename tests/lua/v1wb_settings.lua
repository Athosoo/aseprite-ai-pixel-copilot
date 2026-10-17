-- tests/lua/v1wb_settings.lua -- GUI 探针：设置页（画布内编辑，不弹原生窗）
--
-- 跑法：powershell -File tests\run_gui_v1.ps1 -Mode settings -Out tests\lua\gui_v1_settings.png
--
-- 刻意不连桥：用假 agent 提供 config（含 apiKeyHint），屏幕上一个面板、没有第二个原生窗。
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local workbench = require("lib.workbench")

local agent = {
  docName = function() return "001.ase" end,
  config = {
    baseUrl = "https://api.openai.com/v1", model = "gpt-4o",
    apiKeySet = true, apiKeyHint = "9f2c",
    temperature = 0.2, maxSteps = 24, contextTokens = 16000, thinking = "auto",
    timeoutMs = 180000, maxTurnMs = 600000,
  },
  send = function() return true end,
  action = function() return true end,
}

local wb = workbench.new{ agent = agent, viewId = "settings" }
wb:setSize(900, 620)
pcall(function() wb:mount(nil, agent) end)
wb:setDoc{ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 }
wb:setStatus("connected - gpt-4o", "ok")
wb:setView("settings")
wb:show()

_G.__v1wbWorkbench = wb
_G.__v1wbTimer = Timer{ interval = 0.1, ontick = function() end }   -- 只保活，不手动 repaint
