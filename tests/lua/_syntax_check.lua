local paths = {
  "C:/Users/18316/AppData/Roaming/Aseprite/extensions/ai-pixel-copilot/main.lua",
  "C:/Users/18316/AppData/Roaming/Aseprite/extensions/ai-pixel-copilot/lib/workbench.lua",
  "C:/Users/18316/AppData/Roaming/Aseprite/extensions/ai-pixel-copilot/lib/panel_adapter.lua",
  "C:/Users/18316/AppData/Roaming/Aseprite/extensions/ai-pixel-copilot/kernel/init.lua",
}
for _, p in ipairs(paths) do
  local f, err = loadfile(p)
  print((f and "OK   " or "FAIL ") .. p .. (f and "" or ("  <- " .. tostring(err))))
end
