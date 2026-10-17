-- tests/lua/v1wb_canvas.lua -- GUI 探针：画布页（中文算子标题的清晰度）
--
-- 跑法：powershell -File tests\run_gui_v1.ps1 -Mode canvas -Out tests\lua\gui_v1_canvas.png
--
-- 刻意**不装载真能力包**：kernel.dsl.loadFile 用 io.open，本机 [script_access] 为空，
-- 一调就弹原生授权框，截图会变成模态框。这里用假 registry 提供与真包同名的中文算子标签，
-- 足以验证「中文标题不做假粗」这件事 —— 糊不糊只跟绘制次数有关，跟数据来源无关。
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local workbench = require("lib.workbench")

local OPS = {
  { name = "contrast", label = "加强明暗对比", params = { { name = "amount" }, { name = "pivot" } } },
  { name = "sharpen",  label = "锐化边缘",     params = { { name = "amount" }, { name = "threshold" } } },
  { name = "quantize", label = "自动减色",     params = { { name = "colors" } } },
  { name = "despeckle",label = "清杂点",       params = { { name = "maxCluster" } } },
}
local fakeRegistry = {}
function fakeRegistry:list(kind)
  if kind ~= "op" then return {} end
  return OPS
end
function fakeRegistry:get(kind, id)
  for _, o in ipairs(OPS) do if o.name == id then return o end end
  return nil
end
function fakeRegistry:fingerprint() return "gui-probe" end

local agent = { docName = function() return "001.ase" end }
local wb = workbench.new{ agent = agent, viewId = "canvas" }
wb:setSize(900, 620)
pcall(function() wb:mount({ registry = fakeRegistry, host = {}, ledger = {} }, agent) end)

wb:setDoc{ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 }
wb:setStatus("connected - gpt-4o", "ok")
wb:setView("canvas")
wb:show()

_G.__v1wbWorkbench = wb
_G.__v1wbTimer = Timer{
  interval = 0.1,
  ontick = function()
    -- 不调 repaint：重绘链路已经是工作台自己的事（invalidate -> dlg:repaint），
    -- 探针再手调会掩盖真问题。这里 Timer 只负责保活，别让 Dialog 被 GC。
  end,
}
