-- tests/lua/v1wb_paint.lua -- bisect probe: min + one timer repaint tick
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"
local workbench = require("lib.workbench")
local wb = workbench.new{}
wb:setSize(900, 620)
wb:show()
local n = 0
_G.__wb = wb
_G.__t = Timer{ interval = 0.2, ontick = function()
  n = n + 1
  if n > 2 then return end
  pcall(function() wb:repaint() end)
end }
