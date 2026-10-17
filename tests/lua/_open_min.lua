_G.__selfClickTarget = "min"
local ok, err = pcall(function() app.command.ai_pixel_copilot_open() end)
print("open ok=" .. tostring(ok) .. " err=" .. tostring(err))
