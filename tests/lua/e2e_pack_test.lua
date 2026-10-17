-- tests/lua/e2e_pack_test.lua -- 端到端自扩展链路：能力包的算子要被看见、被执行、被限时
--
-- 跑法（仓库根）：
--   $env:ASE_PROJ="D:\PraticleTool\Aseprite-AI"
--   & "<Aseprite>\aseprite.exe" -b --script tests/lua/e2e_pack_test.lua
--
-- 这套断言回答一个问题：**模型给自己写一个算子，之后它自己能用上吗？**
-- 四个环节缺一个，"自扩展"就只是半句话：
--   装载（manifest + main.lua 真的读进来）
--   → 名单（上报给桥的 ops 里出现这个名字）
--   → 执行（点下去真的改像素，且走的是带沙箱预算的 kernel:invoke）
--   → 刹车（死循环算子被掐断、返回可读超时、UI 不卡）
--   → 卸载（包没了，名字也得从名单里消失，不能留 ghost）

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local ops = require("lib.ops")
local agent = require("lib.agent")
local kernelInit = require("kernel.init")
local workbench = require("lib.workbench")

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
local function contains(list, want)
  for _, v in ipairs(list or {}) do if v == want then return true end end
  return false
end

----------------------------------------------------------------------
-- 临时能力包：一个真算子 + 一个死循环算子
----------------------------------------------------------------------

local function tempDir(tag)
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  local dir = string.format("%s/ai-pixel-copilot-e2e-%s-%d-%d", base, tag, os.time(), math.random(1000))
  pcall(function() app.fs.makeAllDirectories(dir) end)
  return dir
end

local function writeFile(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- 包代码跑在沙箱里：没有 app / Image / Color，只能用 ctx 交进来的 host 做像素活。
-- 这是刻意的分层 —— 像素实现在内核，包只负责编排。
local PACK_LUA = [==[
local function shiftBytes(scratch, amount, count)
  local bytes = scratch.bytes
  local out = {}
  local i = 1
  local n = #bytes
  while i <= n do
    local r = string.byte(bytes, i)
    local g = string.byte(bytes, i + 1)
    local b = string.byte(bytes, i + 2)
    local a = string.byte(bytes, i + 3)
    if a > 0 then
      r = (r + amount) % 256
      count.n = count.n + 1
    end
    out[#out + 1] = string.char(r, g, b, a)
    i = i + 4
  end
  scratch.bytes = table.concat(out)
  return count.n
end

return function(ctx)
  local reg = ctx.registry
  reg:define("op", {
    name = "t4_invert",
    label = "通道位移",
    params = { { name = "amount", type = "integer" } },
    run = function(host, params)
      local active = host:active()
      if not active then return { changed = 0, elided = true, detail = "no document is open" } end
      local cels, rerr = host:resolveCels(active.sprite, active.frame, params.layers)
      if not cels then return { changed = 0, elided = true, detail = rerr } end
      local amount = tonumber(params.amount) or 16
      local total = 0
      local okApply, aerr = host:apply("op t4_invert", function(h)
        total = h:drawCells(cels, function(scratch)
          return shiftBytes(scratch, amount, { n = 0 })
        end)
      end)
      if not okApply then return { changed = 0, elided = true, detail = tostring(aerr) } end
      return { changed = total, elided = false, detail = string.format("t4_invert: %d px", total) }
    end,
  })

  reg:define("op", {
    name = "t4_deadloop",
    label = "死循环",
    params = {},
    run = function() while true do end end,
  })
end
]==]

local function makePack(root, id, opsDecl, srcLua)
  local d = root .. "/" .. id
  pcall(function() app.fs.makeAllDirectories(d) end)
  local decl = {}
  for _, n in ipairs(opsDecl) do decl[#decl + 1] = string.format('{"name":"%s"}', n) end
  writeFile(d .. "/manifest.json", string.format(
    '{"id":"%s","name":"T4 demo","version":"0.0.1","api":1,"permissions":[],"ops":[%s]}',
    id, table.concat(decl, ",")))
  writeFile(d .. "/main.lua", srcLua)
  return d
end

local packRoot = tempDir("packs")
makePack(packRoot, "t4demo", { "t4_invert", "t4_deadloop" }, PACK_LUA)

local SANDBOX_MS = 150
local kernel = kernelInit.new({
  app = app,
  sandboxMs = SANDBOX_MS,
  shared = { ops = ops },
  ledger = { dir = tempDir("journal"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin", packRoot } },
})

print("== 1. 装载：临时能力包真的被读进来 ==")
local mounted, packErrors = kernelInit.mountPacks(kernel, {})
ok(type(mounted) == "table", "mountPacks 返回包清单")
local demoPack = nil
for _, p in ipairs(mounted) do if p.id == "t4demo" then demoPack = p end end
ok(demoPack ~= nil, "t4demo 装载成功", #mounted .. " packs / " .. #packErrors .. " errors")
eq(#packErrors, 0, "没有装载错误")
ok(kernel.registry:get("op", "t4_invert") ~= nil, "包算子进了 registry")
ok(kernel.registry:get("op", "t4_invert").run ~= nil, "registry 里的 op 带 run()")
eq(kernel.registry:get("op", "t4_invert").label, "通道位移", "manifest/main.lua 的 label 传到了 registry")

print("== 2. 名单：上报给桥的 ops = registry ∪ lib.ops ==")
local names = agent.opNames(kernel)
ok(contains(names, "t4_invert"), "名单里有包算子（模型看得见了）")
ok(contains(names, "t4_deadloop"), "名单里有第二个包算子")
for _, legacy in ipairs(ops.names) do
  ok(contains(names, legacy), "内建算子仍在名单里：" .. legacy)
end
eq(#names, #ops.names + 2, "名单 = 内建 10 + 包 2，无重复")
local sorted = true
for i = 2, #names do if names[i - 1] > names[i] then sorted = false end end
ok(sorted, "名单有序（前端展示稳定）")

local help = agent.opsHelp(kernel)
ok(help:find("- replace_color", 1, true) ~= nil, "能力说明保留内建算子的原文")
ok(help:find("t4_invert", 1, true) ~= nil, "能力说明里也列了包算子")
ok(help:find("能力包注册", 1, true) ~= nil, "包算子标了来源")

-- 没有内核（main.lua 还没接线）时：名单退回内建、执行退回老路径，不崩
eq(#agent.opNames(nil), #ops.names, "无内核时名单只有内建算子")
ok(agent.isPackOp(nil, "t4_invert") == false, "无内核时不把包算子当能力包算子")

print("== 3. 执行：包算子真的改像素，且走 kernel:invoke ==")
local spr = Sprite(8, 8, ColorMode.RGB)
app.activeSprite = spr
local cel = app.activeCel
cel.image:clear(Rectangle(0, 0, 8, 8), Color(10, 20, 30))

local okExec, res = pcall(agent.execOps, { { op = "t4_invert", amount = 16 } }, "e2e", { cel }, kernel)
ok(okExec, "包算子执行不抛错", tostring(res))
ok(type(res) == "table" and res.ops and res.ops[1] ~= nil, "报告里有 ops[1]")
eq(res.ops[1] and res.ops[1].op, "t4_invert", "报告里记的是包算子名字")
eq(res.ops[1] and res.ops[1].changed, 64, "8x8 全不透明 = 64 px 被改")
local px = cel.image:getPixel(0, 0)
eq(px, Color(26, 20, 30).rgbaPixel, "像素真的变了（R 通道 +16）")
ok(res.elided ~= true, "不算被省略")

-- 内建算子仍然走 lib.ops 的批量事务，报告形状不变
cel.image:clear(Rectangle(0, 0, 8, 8), Color(255, 0, 0))
local okLegacy, legacyRes = pcall(agent.execOps,
  { { op = "replace_color", from = "#FF0000", to = "#00FF00" } }, "e2e", { cel }, kernel)
ok(okLegacy, "内建算子执行不抛错", tostring(legacyRes))
eq(legacyRes.ops[1] and legacyRes.ops[1].changed, 64, "内建算子仍然改满 64 px")
ok(legacyRes.sprite ~= nil and legacyRes.frame ~= nil, "内建报告仍带 sprite/frame（桥依赖这两个字段）")
ok(legacyRes.hint == nil, "改到了像素就不该给「没改到」的提示")

print("== 4. 混合请求：按请求顺序执行，两种来源都记账 ==")
cel.image:clear(Rectangle(0, 0, 8, 8), Color(1, 2, 3))
local okMix, mixRes = pcall(agent.execOps, {
  { op = "fill_region", region = { x = 0, y = 0, w = 8, h = 8 }, color = "#0000FF" },
  { op = "t4_invert", amount = 8 },
}, "e2e", { cel }, kernel)
ok(okMix, "混合请求执行不抛错", tostring(mixRes))
eq(#mixRes.ops, 2, "两条请求各出一条报告")
eq(mixRes.ops[1].op, "fill_region", "第一条仍是内建算子（顺序没被打乱）")
eq(mixRes.ops[2].op, "t4_invert", "第二条是包算子")
eq(mixRes.ops[1].changed, 64, "内建那步改满")
eq(mixRes.ops[2].changed, 64, "包算子那步也改满")
-- fill_region 先把整块刷成 #0000FF，包算子再给 R 加 8 -> (8, 0, 255)
eq(cel.image:getPixel(0, 0), Color(8, 0, 255).rgbaPixel, "两步叠加后的像素值正确（#0000FF 再 +R8）")

print("== 5. 刹车：死循环算子被掐断，且返回可读错误 ==")
local t0 = os.clock()
local okLoop, loopErr = pcall(agent.execOps, { { op = "t4_deadloop" } }, "e2e", { cel }, kernel)
local loopMs = (os.clock() - t0) * 1000
ok(not okLoop, "死循环算子执行失败（不是静默成功）")
ok(tostring(loopErr):find("sandbox timeout after", 1, true) ~= nil,
   "错误文本是可读的超时原因", tostring(loopErr))
ok(tostring(loopErr):find("t4_deadloop", 1, true) ~= nil, "错误里带得上算子名字（模型能定位）")
ok(loopMs < SANDBOX_MS * 6, string.format("掐断没有卡死：%.0fms（预算 %dms）", loopMs, SANDBOX_MS), loopMs)

print("== 6. 未知算子：仍走老路径的报错文案 ==")
local okUnknown, unknownErr = pcall(agent.execOps, { { op = "no_such_op" } }, "e2e", { cel }, kernel)
ok(not okUnknown, "未知算子报错")
ok(tostring(unknownErr):find("unknown op", 1, true) ~= nil, "错误文案保持 v0.5.x 的 unknown op", tostring(unknownErr))
ok(tostring(unknownErr):find("replace_color", 1, true) ~= nil, "并把可用算子列出来（模型可自愈）")

print("== 7. 视图限时：能力包写的 view 卡不死 UI ==")
do
  -- 用真 registry：直接往里塞两个坏视图（正是"包注册了视图"的样子）
  kernel.registry:define("view", {
      id = "t4_hang_mount", title = "HangMount", icon = "!",
      mount = function() while true do end end,
    })
    kernel.registry:define("view", {
      id = "t4_hang_render", title = "HangRender", icon = "!",
      mount = function() return { id = "t4_hang_render", title = function() return "hang" end,
                                 actions = function() return {} end,
                                 render = function() while true do end end } end,
  })

    local wb = workbench.new({ width = 900, height = 620 })
    wb:mount(kernel, nil)
    wb:setSize(900, 620)

    local gc = { width = 900, height = 620, texts = {} }
    gc.measureText = function(_, s) return { width = (utf8.len(tostring(s or "")) or 0) * 6, height = 12 } end
    gc.fillRect = function() end
    gc.fillText = function() end
    gc.drawImage = function() end

    local mt0 = os.clock()
    wb:setView("t4_hang_mount")
    wb:paint(gc)
    local mountMs = (os.clock() - mt0) * 1000
    ok(mountMs < SANDBOX_MS * 6, string.format("死循环 mount 没卡死：%.0fms", mountMs), mountMs)
    ok(tostring(wb.viewErrors and wb.viewErrors.t4_hang_mount or ""):find("sandbox timeout", 1, true) ~= nil,
       "死循环 mount 的原因记进了 viewErrors", wb.viewErrors and wb.viewErrors.t4_hang_mount)

    wb:setView("t4_hang_render")
    wb:invalidate()
    local rt0 = os.clock()
    wb:paint(gc)
    local renderMs = (os.clock() - rt0) * 1000
    ok(renderMs < SANDBOX_MS * 6, string.format("死循环 render 没卡死：%.0fms", renderMs), renderMs)
    ok(tostring(wb.lastViewError or ""):find("sandbox timeout", 1, true) ~= nil,
       "死循环 render 的原因留在 lastViewError", wb.lastViewError)
end

print("== 8. 卸载：包没了，名字也必须消失 ==")
local removed = agent.dropPackOps(kernel, "t4demo")
eq(removed, 2, "撤掉 manifest 里声明的 2 个算子")
local afterNames = agent.opNames(kernel)
ok(not contains(afterNames, "t4_invert"), "卸载后名单里没有 t4_invert（不留 ghost）")
ok(not contains(afterNames, "t4_deadloop"), "卸载后名单里没有 t4_deadloop")
eq(#afterNames, #ops.names, "名单回到只有内建算子的状态")
ok(contains(afterNames, "replace_color"), "内建算子不受影响")
local okGone = pcall(agent.execOps, { { op = "t4_invert", amount = 4 } }, "e2e", { cel }, kernel)
ok(not okGone, "卸载后调用包算子会失败（不会静默用旧实现）")

print("== 9. 接线：agent 认 cfg.kernel；没内核时仍是安全降级 ==")
do
  local wired = agent.new({ port = 8777, bridgeHint = "node", kernel = kernel })
  ok(wired:kernel() == kernel, "agent 从 cfg.kernel 拿到内核（main.lua 走的就是这条）")
  eq(wired:dropPackOps("no_such_pack"), 0, "有内核但包不存在时 dropPackOps 返回 0")
  if wired.destroy then pcall(function() wired:destroy() end) end

  local bare = agent.new({ port = 8777, bridgeHint = "node" })
  eq(bare:kernel(), nil, "没有内核时 kernel() 返回 nil（安全降级）")
  eq(#agent.opNames(bare:kernel()), #ops.names, "没有内核时名单只有内建算子")
  eq(bare:dropPackOps("t4demo"), 0, "没有内核时 dropPackOps 不崩、返回 0")
  if bare.destroy then pcall(function() bare:destroy() end) end
end

print("== 10. 启停接线：ledger 发事件 → 入口撤算子（不留 ghost） ==")
do
  -- 第 8 节已经把 t4demo 的算子撤了，这里重新装载
  kernelInit.mountPacks(kernel, {})
  ok(contains(agent.opNames(kernel), "t4_invert"), "重新装载后名单里有 t4_invert")

  local chunk = assert(loadfile(EXT .. "/main.lua"))
  chunk()
  ok(type(wirePackEvents) == "function", "main.lua 导出了事件接线函数")

  local dropped = {}
  local subs = wirePackEvents(function() return kernel end, function(id)
    dropped[#dropped + 1] = id
    return agent.dropPackOps(kernel, id)
  end)
  eq(type(subs) == "table" and #subs or 0, 2, "bus 上挂了 pack.disabled 与 pack.rolledback 两个订阅")

  kernel.ledger:disable("t4demo")
  eq(dropped[1], "t4demo", "disable 之后入口收到 pack.disabled")
  ok(not contains(agent.opNames(kernel), "t4_invert"), "disable 之后名单里没有 t4_invert")
  ok(not contains(agent.opNames(kernel), "t4_deadloop"), "disable 之后第二个包算子也没了")
  eq(#agent.opNames(kernel), #ops.names, "disable 后名单退回内建 10 个")

  kernel.ledger:enable("t4demo")
  ok(not contains(agent.opNames(kernel), "t4_invert"), "enable 只解除禁用，不自动重注册")
  kernelInit.mountPacks(kernel, {})
  ok(contains(agent.opNames(kernel), "t4_invert"), "重新 mount 后名字回来了")

  -- rollback：回滚到上一版，名单必须回到上一版的算子集合
  local srcRoot = tempDir("rollsrc")
  local function writeRollPack(version, names)
    local d = srcRoot .. "/v" .. version .. "/t5roll"
    pcall(function() app.fs.makeAllDirectories(d) end)
    local decl = {}
    for _, n in ipairs(names) do decl[#decl + 1] = string.format('{"name":"%s"}', n) end
    writeFile(d .. "/manifest.json", string.format(
      '{"id":"t5roll","name":"T5 roll","version":"%d.0.0","api":1,"permissions":[],"ops":[%s]}',
      version, table.concat(decl, ",")))
    local regs = {}
    for _, n in ipairs(names) do
      regs[#regs + 1] = string.format(
        'reg:define("op", { name = "%s", label = "%s", params = {}, run = function() return { changed = 0, elided = true, detail = "stub" } end })', n, n)
    end
    writeFile(d .. "/main.lua", "return function(ctx) local reg = ctx.registry " .. table.concat(regs, " ") .. " end")
    return d
  end

  local v1 = writeRollPack(1, { "t5_a", "t5_b" })
  local v2 = writeRollPack(2, { "t5_a" })

  kernel.ledger:install(v1)
  kernelInit.mountPacks(kernel, {})
  ok(contains(agent.opNames(kernel), "t5_a") and contains(agent.opNames(kernel), "t5_b"),
     "v1 装好后名单里两个算子都在")

  kernel.ledger:install(v2)
  agent.dropPackOps(kernel, "t5roll")     -- 激活新版本前撤旧算子（install 本身不发事件）
  kernelInit.mountPacks(kernel, {})
  ok(contains(agent.opNames(kernel), "t5_a") and not contains(agent.opNames(kernel), "t5_b"),
     "v2 装好后名单只剩一个算子")

  kernel.ledger:rollback("t5roll")
  ok(contains(dropped, "t5roll"), "rollback 之后入口收到 pack.rolledback")
  ok(not contains(agent.opNames(kernel), "t5_a"), "rollback 先撤掉当前版本的算子（不留 ghost）")
  kernelInit.mountPacks(kernel, {})
  ok(contains(agent.opNames(kernel), "t5_a") and contains(agent.opNames(kernel), "t5_b"),
     "rollback 后重新 mount 回到上一版的两个算子")
end

print("")
print(string.format("%d passed, %d failed", pass, fail))
