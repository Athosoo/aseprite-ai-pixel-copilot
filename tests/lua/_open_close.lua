_G.__selfClickTarget = "close"
local ok, err = pcall(function() app.command.ai_pixel_copilot_open() end)
print("open ok=" .. tostring(ok) .. " err=" .. tostring(err))
