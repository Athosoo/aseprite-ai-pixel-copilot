-- tests/lua/v1wb_common.lua -- workbench GUI probe builder (render-only)
--
-- Deliberately touches NO io/os/WebSocket: this machine's [script_access] section is
-- empty, so any such call pops a native permission modal in GUI mode and the
-- screenshot becomes a picture of a dialog box instead of the panel.
-- ROOT is therefore hardcoded; this file is a GUI rendering probe, not a portable test.
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua;" .. ROOT .. "/tests/lua/?.lua"

local function demoAgent()
  return {
    docName = function() return "001.ase" end,
    status = "connected",
  }
end

return function(mode)
  local workbench = require("lib.workbench")
  local wb = workbench.new{ agent = demoAgent() }
  wb:setSize(900, 620)
  pcall(function() wb:mount(nil, demoAgent()) end)

  wb:setDoc{ name = "001.ase", w = 32, h = 32, layers = 4, frame = 1, frames = 1 }
  wb:setStatus("connected - gpt-4o", { tone = "ok" })

  if mode == "offline" then
    wb:setConnected(false, {
      reason = "bridge refused: ws://127.0.0.1:8777",
      cmd = 'node "D:/PraticleTool/Aseprite-AI/bridge/src/server.mjs"',
    })
  end

  wb:log("make the red on this layer a bit darker", "user", { ts = 1750000000000 })
  wb:log("Got it - layer 2. Snapshot first.", "ai")
  wb:log("replace_color  256 px  (undoable)", "tool")
  wb:log("outline  128 px", "tool")
  wb:log("snapshot v3 taken before: darker red", "info")

  wb:setView(mode == "packs" and "packs" or "console")
  wb:setBusy(false)
  wb:show()

  -- Keep the script (and therefore the Dialog) alive: Aseprite collects the dialog as
  -- soon as the chunk returns, and a collected dialog with a live window crashes the
  -- host. The timer is the same keep-alive trick gui_panel_probe.lua uses.
  _G.__v1wbTimer = Timer{
    interval = 0.1,
    ontick = function()
      pcall(function() wb:repaint() end)
    end,
  }
  _G.__v1wbWorkbench = wb
  return wb
end