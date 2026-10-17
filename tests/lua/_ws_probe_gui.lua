-- 直接测扩展的 ws 层能不能连上桥（GUI 模式，回调才会触发）
local ROOT = "D:/PraticleTool/Aseprite-AI"
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"
print("P0 start")
local okLoad, ws = pcall(require, "lib.ws")
print("P1 require ws ok=" .. tostring(okLoad) .. " err=" .. tostring(ws))
if not okLoad then return end
_G.__keep = {}
local conn
local ok, err = pcall(function()
  conn = ws.connect("ws://127.0.0.1:8777", {
    onOpen = function() print("P3 WS OPEN") end,
    onError = function(e) print("P3 WS ERROR " .. tostring(e)) end,
    onText = function(m) print("P3 WS TEXT " .. tostring(m)) end,
    onClose = function() print("P3 WS CLOSE") end,
  })
end)
print("P2 connect ok=" .. tostring(ok) .. " err=" .. tostring(err) .. " conn=" .. tostring(conn))
_G.__conn = conn
