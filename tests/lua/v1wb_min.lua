-- tests/lua/v1wb_min.lua -- bisect probe: build + show only, no demo state, no repaint loop
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"
local workbench = require("lib.workbench")
local wb = workbench.new{}
wb:setSize(900, 620)
wb:show()
_G.__wb = wb
_G.__t = Timer{ interval = 0.2, ontick = function() end }
