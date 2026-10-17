-- 尝试从脚本直接调用插件命令打开面板（不依赖窗口前台 / 不依赖 Timer）
local names = {}
if app.commands then
  for _, c in ipairs(app.commands) do names[#names+1] = c.id end
end
print("commands count=" .. tostring(#names))
local hit = nil
for _, id in ipairs(names) do
  if tostring(id):find("ai_pixel") then print("plugin command: " .. tostring(id)); hit = hit or id end
end
if app.command and app.command.ai_pixel_copilot_open then
  print("calling app.command.ai_pixel_copilot_open()")
  local ok, err = pcall(function() app.command.ai_pixel_copilot_open() end)
  print("call ok=" .. tostring(ok) .. " err=" .. tostring(err))
else
  print("app.command.ai_pixel_copilot_open = " .. tostring(app.command and app.command.ai_pixel_copilot_open))
end
