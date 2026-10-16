-- tests/lua/gui_bar_probe.lua -- 底边栏 / 侧边栏探针（P12）
--
-- 两件事：
--   A) 主窗口几何到底能拿到什么（决定"贴边"能不能算坐标）
--   B) 真面板跑一遍形态切换，把三种形态的窗口尺寸打出来（GUI 回归用）
--
-- 已知结论（别重复探）：
--   * app.window 有 .width / .height（实测 960x564，UI 单位，和 dlg.bounds 同尺子），
--     但**没有** bounds / x / y / scale —— 拿得到主窗口的"大小"，拿不到"位置"。
--   * app.workspace 是 nil；app.theme 只暴露一个 color 成员。
--   结论：可以按主窗口尺寸把栏**贴到右下角**（dlg.bounds 的原点就是主窗口内容区左上角），
--   但"用户把主窗口挪到副屏"这类情况我们感知不到，所以仍然提供手动拖的余地。
--
-- GUI Aseprite 在 Windows 上没有控制台，结论写文件（ASE_PROBE_OUT）。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local OUT = os.getenv("ASE_PROBE_OUT")
if not OUT or OUT == "" then OUT = "gui_bar_probe.out" end

local writeErr = nil
local function say(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  line = "[bar-probe] " .. line
  pcall(print, line)
  local ok, err = pcall(function()
    local f, oerr = io.open(OUT, "a")
    if not f then error(tostring(oerr)) end
    f:write(line .. "\n")
    f:close()
  end)
  if not ok then writeErr = tostring(err) end
end

-- 字段存在性探测：userdata 的 __index 会直接抛，所以必须包在 pcall 里
local function field(label, getter)
  local ok, v = pcall(getter)
  say("%-24s ok=%s -> %s", label, tostring(ok), tostring(ok and v or nil))
end

local function run()
  say("== A) 主窗口几何：到底有什么字段 ==")
  field("type(app.window)", function() return type(app.window) end)
  for _, k in ipairs({ "width", "height", "bounds", "scale", "x", "y", "position",
                       "screenWidth", "screenHeight", "title", "isVisible" }) do
    field("app.window." .. k, function() return tostring(app.window[k]) end)
  end
  field("type(app.workspace)", function() return type(app.workspace) end)
  field("app.uiScale", function() return tostring(app.uiScale) end)
  field("app.isUIAvailable", function() return tostring(app.isUIAvailable) end)

  -- B) 真面板跑一遍形态切换
  say("== B) 真面板的形态切换 ==")
  local panelMod = require("lib.panel")
  local p = panelMod.new{}
  p:show()
  if not p.dlg then
    say("B) 面板建不起来（无头？）")
    return
  end

  local function bounds()
    local ok, b = pcall(function() return p.dlg.bounds end)
    if not ok or not b then return "?" end
    return string.format("%dx%d @ (%d,%d)", b.width or 0, b.height or 0, b.x or 0, b.y or 0)
  end

  p:log("形态探针：这是一行日志，用来验证栏模式下画不画得出来。", "ai")
  p:setStatus("thinking...", "busy", "hero.ase")

  say("B0 面板形态 bounds = %s", bounds())
  say("B1 切底边栏 -> %s", p:setMode("bar_bottom"))
  say("B2 底边栏 bounds = %s   (期望宽而矮:~1012x91)", bounds())
  say("B3 切侧边栏 -> %s", p:setMode("bar_side"))
  say("B4 侧边栏 bounds = %s   (期望窄而高:~332x467)", bounds())
  say("B5 切回面板 -> %s", p:setMode("panel"))
  say("B6 面板 bounds = %s   (期望 ~672x467)", bounds())
  say("B7 cycleMode -> %s", p:cycleMode())
  say("B8 bounds = %s", bounds())

  -- 小窗（最小化）必须贴右下角：v0.5.9 起从"右侧居中"改成"右下角"。
  -- 这里打的是真窗口的 bounds，跟 panel.anchorFor 的算式对得上才算过。
  say("B8b 切小窗 -> %s", p:setMode("small"))
  local sb = bounds()
  say("B8c 小窗 bounds = %s   (期望贴右下角)", sb)
  local sw, sh = nil, nil
  pcall(function() sw = app.window.width; sh = app.window.height end)
  local bw2, bh2, bx, by = sb:match("^(%d+)x(%d+) @ %((%-?%d+),(%-?%d+)%)$")
  if sw and bx then
    say("B8d 主窗口 %sx%s；小窗右边距 %d 底边距 %d（都该是 0 附近）",
      tostring(sw), tostring(sh),
      sw - (tonumber(bx) + tonumber(bw2)), sh - (tonumber(by) + tonumber(bh2)))
  end
  say("B8e 切回面板 -> %s", p:setMode("panel"))

  p:fillInput("测试输入")
  say("B9 栏模式下 fillInput 没炸，input=%s", tostring(p.input))

  -- C) 用主窗口尺寸算"贴右下角"的坐标，看 Aseprite 接受不接受
  say("== C) 按主窗口尺寸贴右下角 ==")
  local ww, wh = nil, nil
  pcall(function() ww = app.window.width; wh = app.window.height end)
  say("C0 主窗口尺寸 = %s x %s", tostring(ww), tostring(wh))
  if ww and wh then
    local c = { w = 1000, h = 44 }
    local x, y = math.max(0, ww - c.w - 12), math.max(0, wh - c.h - 47)
    say("C1 目标 bounds = (%d,%d) %dx%d", x, y, c.w + 12, c.h + 47)
    local okSet = pcall(function() p.dlg.bounds = Rectangle(x, y, c.w + 12, c.h + 47) end)
    say("C2 设置 ok=%s 读回 = %s", tostring(okSet), bounds())
  end

  -- 停在底边栏让外部截图（run_gui_bar.sh 会在 ~5s 时截），8 秒后自己关掉
  p:setMode("bar_bottom")
  p:log("（探针停在底边栏，等待截图）", "info")
  say("RESULT=DONE")
  local t
  t = Timer{
    interval = 8.0,
    ontick = function()
      t:stop()
      pcall(function() p.dlg:close() end)
    end,
  }
  t:start()
end

say("PROBE START")
local ok, err = pcall(run)
if not ok then say("RESULT=FAIL -- %s", tostring(err)) end
if writeErr then say("WRITE-ERR: %s", tostring(writeErr)) end
say("PROBE EXIT")
