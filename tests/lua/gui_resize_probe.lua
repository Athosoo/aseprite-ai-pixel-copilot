-- tests/lua/gui_resize_probe.lua -- 窗口尺寸行为探针（P4）
--
-- 要回答两个问题（结论靠 print 出来的数字，不用肉眼看窗口）：
--   A) 缩小窗口后，点一下画布内部（onmousedown -> dlg:modify{focus}）
--      会不会把窗口"撑回原大小"？是 modify 触发的，还是布局本来就撑？
--   B) canvas 的 autoscaling=true 时，窗口能被缩到比内容还小吗
--      （缩到元素消失）？autoscaling=false 能钳住吗？
--
-- 跑法： bash tests/run_gui_resize.sh        （会起 GUI + 把日志打出来）
-- 或者手动： ASE_PROJ=<仓库根> aseprite --script tests/lua/gui_resize_probe.lua
--
-- 注意：dlg.bounds 只在窗口可见时读才安全（不可见时读会触发 autoRemap 重新居中）。

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local panel = require("lib.panel")

-- Windows 上的 GUI Aseprite 没有控制台（io.stdout 可能是 nil），print 出去就没了
-- —— 结论必须落盘。写文件本身也可能被授权挡，所以全程 pcall 包着。
local OUT = os.getenv("ASE_PROBE_OUT")
if not OUT or OUT == "" then OUT = ROOT .. "/tests/lua/gui_resize_probe.out" end

local writeErr = nil
local function say(fmt, ...)
  local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  line = "[resize-probe] " .. line
  pcall(print, line)
  pcall(function() if io.stdout then io.stdout:flush() end end)
  local ok, err = pcall(function()
    local f, oerr = io.open(OUT, "a")
    if not f then error(tostring(oerr)) end
    f:write(line .. "\n")
    f:close()
  end)
  if not ok then writeErr = tostring(err) end
end

local function boundsOf(dlg)
  local ok, b = pcall(function() return dlg.bounds end)
  if not ok or not b then return nil end
  return b
end

local function desc(b)
  if not b then return "nil" end
  return string.format("x=%d y=%d w=%d h=%d", b.x, b.y, b.width or b.w, b.height or b.h)
end

local function trySet(dlg, x, y, w, h)
  local ok, err = pcall(function() dlg.bounds = Rectangle(x, y, w, h) end)
  return ok, err
end

local results = {}

local function run()
  local spr = Sprite(16, 16, ColorMode.RGB)
  app.activeSprite = spr

  local p = panel.new{}
  p:show()

  local dlg = p.dlg
  if not dlg then
    say("RESULT=FAIL -- no dialog (headless?)")
    return
  end

  local b0 = boundsOf(dlg)
  say("A0 初始 bounds: %s", desc(b0))
  say("A0b naturalBounds 记到了吗: %s",
    p.naturalBounds and string.format("%dx%d", p.naturalBounds.w, p.naturalBounds.h) or "nil")

  -- ---- 症状 A：缩小后点画布内部
  local okA = trySet(dlg, b0.x, b0.y, 320, 220)
  say("A1 set 320x220 ok=%s", tostring(okA))
  local b1 = boundsOf(dlg)
  say("A2 读回: %s   <- 如果已经变回原大小，说明 dlg.bounds= 撑不住（布局自己会撑）", desc(b1))
  results.resizeSticks = (b1 and b1.width == 320)

  -- 模拟"点画布空白处"：走真正的处理器。inputFocused 置 false 才是"焦点不在输入框"的路径。
  p.inputFocused = false
  p:_onCanvasMouseDown({ button = MouseButton.LEFT, x = 10, y = 60 }, dlg)
  local b2 = boundsOf(dlg)
  say("A3 点画布后: %s   <- 修好后应该还是 320x220（不再跳回）", desc(b2))

  -- 窗口回到自然尺寸时，点击仍然应该恢复焦点（只是尺寸本来就没变，看不出来）
  p.inputFocused = false
  trySet(dlg, b0.x, b0.y, b0.width, b0.height)
  p:_onCanvasMouseDown({ button = MouseButton.LEFT, x = 10, y = 60 }, dlg)
  local b3 = boundsOf(dlg)
  say("A4 自然尺寸下点一次: %s  inputFocused=%s   <- 应该没跳变且焦点被设回 true",
    desc(b3), tostring(p.inputFocused))

  results.jumpOnShrunkClick = (b2 and b1 and b2.width ~= b1.width)
  say("A结论: 缩过的窗口点击是否跳变=%s  尺寸设置是否生效=%s",
    tostring(results.jumpOnShrunkClick), tostring(results.resizeSticks))

  -- ---- 症状 B：能缩多小
  local okSmall = trySet(dlg, b0.x, b0.y, 120, 90)
  local b4 = boundsOf(dlg)
  say("B1 尝试缩到 120x90 ok=%s 读回: %s", tostring(okSmall), desc(b4))
  results.minW = b4 and b4.width or -1
  results.minH = b4 and b4.height or -1

  local okTiny = trySet(dlg, b0.x, b0.y, 40, 30)
  local b5 = boundsOf(dlg)
  say("B2 尝试缩到 40x30 ok=%s 读回: %s", tostring(okTiny), desc(b5))
  results.tinyW = b5 and b5.width or -1

  -- 画布实际拿到了多大？（_paint 会把 gc.width/height 记在 self.canvasW/H）
  say("B3 画布实际尺寸: %sx%s（缩到很小后元素会不会消失看这个）",
    tostring(p.canvasW), tostring(p.canvasH))

  -- ---- 症状 B 的备选方案：autoscaling = false 能不能钳住？
  -- 【实测结论】钳不住：120x90 照样设得进去，和 autoscaling=true 一样。
  -- 所以面板保留 autoscaling=true，改用"窗口太小"提示兜底（见 panel.lua 的 _paint）。
  -- 这里直接建一个和面板结构类似的最小对话框（不走 Panel，免得被面板逻辑干扰）
  do
    local d2 = Dialog{ title = "autoscaling=false probe", resizeable = true }
    if d2 then
      d2:canvas{ id = "c", width = 660, height = 420, autoscaling = false,
                 onpaint = function() end }
      d2:newrow()
      d2:entry{ id = "e", text = " " }
      d2:samerow()
      d2:button{ id = "b", text = "⏎" }
      local okShow = pcall(function() d2:show{ wait = false } end)
      say("C0 autoscaling=false 对话框 show ok=%s", tostring(okShow))
      local c0 = boundsOf(d2)
      say("C1 初始 bounds: %s", desc(c0))
      if c0 then
        trySet(d2, c0.x, c0.y, 120, 90)
        local c1 = boundsOf(d2)
        say("C2 尝试缩到 120x90 读回: %s   <- 实测还是 120x90：autoscaling=false 也钳不住", desc(c1))
        results.fixedMinW = c1 and c1.width or -1
      end
      pcall(function() d2:close() end)
    else
      say("C0 对话框建不起来（无头？）")
    end
  end

  say("RESULT=OK  minW=%d minH=%d tinyW=%d fixedMinW=%d firstClickJump=%s",
    results.minW, results.minH, results.tinyW, results.fixedMinW or -1,
    tostring(results.jumpOnShrunkClick))

  -- 探针结束：关掉窗口，免得留个孤儿窗
  local t
  t = Timer{
    interval = 1.0,
    ontick = function()
      t:stop()
      pcall(function() dlg:close() end)
      say("PROBE DONE")
    end,
  }
  t:start()
end

say("PROBE START out=%s", tostring(OUT))

local ok, err = pcall(run)
if not ok then
  say("RESULT=FAIL -- %s", tostring(err))
end
if writeErr then say("WRITE-ERR: %s", tostring(writeErr)) end
say("PROBE EXIT")
