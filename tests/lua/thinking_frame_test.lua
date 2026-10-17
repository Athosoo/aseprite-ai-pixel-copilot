-- tests/lua/thinking_frame_test.lua -- 思考帧以弱化色显示（不是正文、也不许丢）
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/thinking_frame_test.lua

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local agent = require("lib.agent")

local pass, fail = 0, 0
local function ok(cond, name, extra)
  if cond then
    pass = pass + 1
    print("  ok   " .. name)
  else
    fail = fail + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end
local function eq(a, b, name)
  ok(a == b, name, string.format("got %s want %s", tostring(a), tostring(b)))
end

local function fakePanel()
  local p = { logs = {}, statuses = {} }
  function p:log(t, k) p.logs[#p.logs + 1] = { text = tostring(t), kind = k } end
  function p:setStatus(t, k) p.statuses[#p.statuses + 1] = { text = tostring(t), kind = k } end
  function p:setThinking() end
  function p:setBarColor() end
  function p:setMode() end
  function p:layoutMode() return "panel" end
  function p:isShown() return false end
  function p:show() end
  function p:hide() end
  function p:destroy() end
  return p
end

local function newAgent()
  local a = agent.new{ port = 8777, bridgeHint = "node bridge/src/server.mjs" }
  a.panel = fakePanel()
  return a, a.panel
end

print("== 思考帧 ==")
do
  local a, panel = newAgent()

  a:onMessage({ type = "thinking", text = "先看这层的红色分布" })
  eq(#panel.logs, 1, "thinking 帧产生了一条日志")
  eq(panel.logs[1] and panel.logs[1].kind, "think", "用 think（弱化色 dim）而不是 ai 正文")
  eq(panel.logs[1] and panel.logs[1].text, "先看这层的红色分布", "文本原样透传")

  a:onMessage({ type = "say", text = "懂了，作用在第 2 层。" })
  eq(panel.logs[2] and panel.logs[2].kind, "ai", "普通回答仍是 ai（没被 thinking 抢走）")
  eq(panel.logs[2] and panel.logs[2].text, "懂了，作用在第 2 层。", "回答文本原样")

  a:onMessage({ type = "thinking" })
  eq(#panel.logs, 3, "缺 text 的 thinking 帧也不崩、仍记一条")
  eq(panel.logs[3] and panel.logs[3].kind, "think", "kind 仍是 think")

  a:destroy()
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
if fail > 0 then error(fail .. " 个断言失败") end
