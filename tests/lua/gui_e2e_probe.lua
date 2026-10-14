-- tests/lua/gui_e2e_probe.lua
--
-- GUI 端到端探针：真 Aseprite + 真扩展代码 + 真桥 + mock LLM。
-- 验证那些【无头模式测不了】的东西：
--   1) 面板对话框能否正常构建（canvas + entry + 按钮 + 文件选择器）
--   2) GUI 模式下 WebSocket 回调能否触发
--   3) JSON 协议 + 二进制帧能否收发
--   4) 整条链路：指令 -> LLM -> apply_ops -> 画布真的被改
--
-- 结果写 tests/lua/gui_e2e_result.txt，然后自动退出。
-- 前置：mock LLM 与桥已启动（见 tests/run_gui_e2e.sh）

local OUT = ROOT .. "/tests/lua/gui_e2e_result.txt"
local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"

local log = {}
local function w(s)
  log[#log + 1] = tostring(s)
  print("[probe] " .. tostring(s))
end
local function flush()
  local f = io.open(OUT, "w")
  if f then
    f:write(table.concat(log, "\n") .. "\n")
    f:close()
  end
end

local ok, err = pcall(function()
  package.path = package.path .. ";" .. EXT .. "/?.lua"

  w("gui=" .. tostring(app.isUIAvailable) .. "  aseprite=" .. tostring(app.version))

  local timer  -- 提前声明：finish 里要引用它

  -- 退出前先关掉所有文档，否则 app.exit() 会弹"是否保存"对话框卡住
  local function finish(result)
    w(result)
    if timer then timer:stop() end
    for i = #app.sprites, 1, -1 do
      pcall(function() app.sprites[i]:close() end)
    end
    flush()
    app.exit()
  end

  -- 造一张测试画布：16x16 全红
  local spr = Sprite(16, 16, ColorMode.RGB)
  app.activeSprite = spr
  app.activeCel.image:clear(Rectangle(0, 0, 16, 16), Color(255, 0, 0))
  w("测试画布已建：16x16 全红，(0,0)=" .. string.format("%08X", app.activeCel.image:getPixel(0, 0)))

  local agentModule = require("lib.agent")
  local agent = agentModule.new{ port = 8777, bridgeHint = "(测试)" }
  w("agent 已创建")

  agent:open()
  w("面板已打开（对话框构建成功）")

  agent:sendChat("把画布上的红色换成蓝色")
  w("已发送指令，等待桥和 LLM 回复…")

  local tries = 0
  timer = Timer{
    interval = 0.25,
    ontick = function()
      tries = tries + 1

      local joined = {}
      for _, l in ipairs(agent.panel.lines) do
        joined[#joined + 1] = l.kind .. ": " .. l.text
      end
      local text = table.concat(joined, "\n")

      if text:find("已经换好了") then
        w("收到 AI 最终回复")
        w("---- 面板日志 ----")
        for _, l in ipairs(agent.panel.lines) do
          w("  [" .. l.kind .. "] " .. l.text)
        end

        local px = app.activeCel.image:getPixel(0, 0)
        w(string.format("画布 (0,0) = %08X", px))
        if px == Color(0, 0, 255).rgbaPixel then
          finish("RESULT=OK canvas really turned blue")
        else
          finish("RESULT=FAIL canvas colour is wrong")
        end
        return
      end

      if text:find("出错") or text:find("连接错误") then
        w("检测到错误，提前结束")
        for _, l in ipairs(agent.panel.lines) do w("  [" .. l.kind .. "] " .. l.text) end
        finish("RESULT=FAIL chain reported an error")
        return
      end

      if tries > 80 then
        for _, l in ipairs(agent.panel.lines) do w("  [" .. l.kind .. "] " .. l.text) end
        finish("RESULT=FAIL timed out after 20s")
      end
    end,
  }
  timer:start()
end)

if not ok then
  w("probe script raised: " .. tostring(err))
  w("RESULT=FAIL script error")
  for i = #app.sprites, 1, -1 do pcall(function() app.sprites[i]:close() end) end
  flush()
  app.exit()
end
