-- tests/lua/v1wb_click.lua -- 点击链路诊断
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"
print("M0 loaded")
local workbench = require("lib.workbench")
local wb = workbench.new{ agent = { docName = function() return "001.ase" end } }
wb:setSize(900, 620)
wb:show()
print("M2 shown viewId=" .. tostring(wb.viewId) .. " shown=" .. tostring(wb.shown))

local ticks = 0
_G.__wb = wb
_G.__t = Timer{ interval = 0.2, ontick = function()
  ticks = ticks + 1
  print("tick " .. ticks)
  if ticks == 3 then
    local function step(name, fn)
      local ok, err = pcall(fn)
      print((ok and "OK   " or "FAIL ") .. name .. (ok and "" or ("  <- " .. tostring(err))))
    end
    step("hit tables", function()
      print(string.format("     titleHits=%d actionHits=%d railHits=%d L=%s",
        #(wb.titleHits or {}), #(wb.actionHits or {}), #(wb.railHits or {}), wb.L and "yes" or "nil"))
    end)
    step("click rail packs", function()
      local t = nil
      for _, h in ipairs(wb.railHits or {}) do if h.id == "packs" then t = h end end
      if not t then error("no packs in railHits (count=" .. #(wb.railHits or {}) .. ")") end
      local cx, cy = t.rect.x + math.floor(t.rect.w / 2), t.rect.y + math.floor(t.rect.h / 2)
      local before = wb.viewId
      local res = wb:mouse("click", cx, cy)
      print("     rect=" .. t.rect.x .. "," .. t.rect.y .. " -> click " .. cx .. "," .. cy ..
            "  mouse()=" .. tostring(res) .. "  viewId " .. tostring(before) .. " -> " .. tostring(wb.viewId))
    end)
    step("repaint", function() wb:repaint() end)
    print("M9 diagnostic complete")
  end
end }
print("M3 timer created")
