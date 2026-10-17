-- tests/lua/kernel_test.lua -- 内核无头测试（bus/registry/host/dsl/ledger/init + 薄入口）
-- 跑法： $env:ASE_PROJ="<repo>"; aseprite.exe -b --script tests/lua/kernel_test.lua

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
local EXT = ROOT .. "/extension"
package.path = package.path .. ";" .. EXT .. "/?.lua"

local busMod = require("kernel.bus")
local registryMod = require("kernel.registry")
local hostMod = require("kernel.host")
local dslMod = require("kernel.dsl")
local ledgerMod = require("kernel.ledger")
local kernelInit = require("kernel.init")

local fails, passes = 0, 0
local function check(name, cond, extra)
  if cond then
    passes = passes + 1
    print("  ok   " .. name)
  else
    fails = fails + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end

local function tempDir(tag)
  local base = os.getenv("TEMP") or os.getenv("TMP") or "."
  local dir = string.format("%s/ai-pixel-copilot-test-%s-%d", base, tag, os.time())
  pcall(function() app.fs.makeAllDirectories(dir) end)
  return dir
end

local function writeFile(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function countLines(text)
  local n = 0
  for _ in (text or ""):gmatch("[^\n]+") do n = n + 1 end
  return n
end

-- ---------------------------------------------------------------- bus
print("== kernel.bus ==")
do
  local bus = busMod.new()
  local got = nil
  local id = bus:on("msg", function(p) got = p end)
  check("on 返回 id", type(id) == "number", id)
  bus:emit("msg", { text = "hi" })
  check("emit 把 payload 原样交给 handler", got ~= nil and got.text == "hi", got and got.text)
  check("emit 返回投递条数", bus:emit("msg", { text = "x" }) == 1)
  check("count 反映 handler 数", bus:count("msg") == 1, bus:count("msg"))
  check("off 已知 id 返回 true", bus:off(id) == true)
  check("off 之后 handler 不再收到事件", bus:emit("msg", { text = "y" }) == 0)
  check("off 未知 id 返回 false", bus:off(99999) == false)
  check("on 参数校验", select(1, bus:on(nil, nil)) == nil)

  local journal = {}
  local bus2 = busMod.new({ journal = function(ev) journal[#journal + 1] = ev end })
  local order = {}
  bus2:on("log", function() order[#order + 1] = "a" end)
  bus2:on("log", function() error("handler blew up") end)
  bus2:on("log", function() order[#order + 1] = "b" end)
  bus2:emit("log", {})
  check("handler 抛错不影响其它 handler", table.concat(order, ",") == "a,b", table.concat(order, ","))
  check("handler 抛错写进 journal", #journal == 1 and journal[1].event == "bus.error", journal[1] and journal[1].event)
  check("errors 计数", bus2.errors == 1, bus2.errors)

  local seen = {}
  local bus3 = busMod.new()
  bus3:on("ws.open", function(p) seen[#seen + 1] = p.n end)
  bus3:push("ws.open", { n = 1 })
  bus3:push("ws.open", { n = 2 })
  check("push 不立即派发", #seen == 0, #seen)
  check("drain 返回处理条数", bus3:drain() == 2, bus3:drain())
  check("drain 后 handler 都收到了", #seen == 2 and seen[1] == 1 and seen[2] == 2, table.concat(seen, ","))
  check("drain 之后队列为空", bus3:drain() == 0)
end

-- ------------------------------------------------------------ registry
print("== kernel.registry ==")
do
  local reg = registryMod.new()
  check("define view 成功", reg:define("view", { id = "v1", title = "V1", mount = function() end }) == true)
  local okMissing, errMissing = reg:define("view", { id = "v2", title = "V2" })
  check("缺 mount 被拒且错误点名 mount",
    okMissing == false and tostring(errMissing):find("mount", 1, true) ~= nil, errMissing)
  local okKind, errKind = reg:define("nope", { id = "x" })
  check("未知 kind 被拒",
    okKind == false and tostring(errKind):find("unknown kind", 1, true) ~= nil, errKind)
  check("get 返回同一份 spec", reg:get("view", "v1") ~= nil and reg:get("view", "v1").title == "V1")
  reg:define("view", { id = "v9", title = "V9", icon = "◈", order = 5, mount = function() end })
  local list = reg:list("view")
  check("list 按 order 排序", list[1].id == "v9", list[1].id)
  check("order 缺省 100", reg:get("view", "v1").order == nil and list[2].id == "v1", list[2].id)
  check("同 kind+id 重复注册 = 覆盖",
    reg:define("view", { id = "v1", title = "V1b", mount = function() end }) == true
      and #reg:list("view") == 2 and reg:get("view", "v1").title == "V1b")
  check("remove 成功", reg:remove("view", "v9") == true and reg:get("view", "v9") == nil)
  check("remove 不存在的返回 false", reg:remove("view", "v9") == false)
  local kinds = reg:kinds()
  check("kinds 返回固定五种且有序",
    #kinds == 5 and table.concat(kinds, ",") == "action,command,op,tool,view", table.concat(kinds, ","))

  local fp1 = reg:fingerprint()
  reg:define("op", { name = "sharpen", run = function() end })
  local fp2 = reg:fingerprint()
  check("fingerprint 随变更变化", fp1 ~= fp2, fp1 .. " / " .. fp2)
  check("fingerprint 稳定（不改动就不变）", fp2 == reg:fingerprint())
  check("op 用 name 作 key", reg:get("op", "sharpen") ~= nil)
  local okOp, errOp = reg:define("op", { name = "broken_op" })
  check("op 缺 run 被拒", okOp == false and tostring(errOp):find("run", 1, true) ~= nil, errOp)
  local okTool, errTool = reg:define("tool", { name = "t1", description = "d", run = function() end })
  check("tool 缺 inputSchema 被拒",
    okTool == false and tostring(errTool):find("inputSchema", 1, true) ~= nil, errTool)
end

-- ---------------------------------------------------------------- host
print("== kernel.host: resolveCels 四种 spec ==")
do
  local spr = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = spr
  spr.layers[1].name = "base"
  app.activeCel.image:clear(Rectangle(0, 0, 8, 8), Color(255, 0, 0))

  local host = hostMod.new(app, {})
  local activeCel = app.activeCel

  local cels, err = host:resolveCels(spr, 1, nil)
  check("spec=nil -> 活动 cel", cels ~= nil and #cels == 1 and cels[1] == activeCel, err)

  local l2 = spr:newLayer()
  l2.name = "detail"
  spr:newCel(l2, 1, Image(8, 8, ColorMode.RGB))
  local l3 = spr:newLayer()
  l3.name = "empty"
  app.activeLayer = spr.layers[1]
  local activeCel2 = app.activeCel

  local celsNil2, errNil2 = host:resolveCels(spr, 1, "")
  check("spec=\"\" 等同 nil（老行为不变）",
    celsNil2 ~= nil and #celsNil2 == 1 and celsNil2[1] == activeCel2, errNil2)

  local celsAll = host:resolveCels(spr, 1, "all")
  check("spec=all -> 当前帧全部有 cel 的层（跳过空层）",
    celsAll ~= nil and #celsAll == 2, celsAll and #celsAll)

  local celsName = host:resolveCels(spr, 1, "detail")
  check("spec=name -> 单个层", celsName ~= nil and #celsName == 1
    and celsName[1].layer.name == "detail", celsName and celsName[1].layer.name)

  local celsArr = host:resolveCels(spr, 1, { "detail", "base" })
  check("spec={names} -> 多个层且顺序与入参一致", celsArr ~= nil and #celsArr == 2
    and celsArr[1].layer.name == "detail" and celsArr[2].layer.name == "base",
    celsArr and (tostring(celsArr[1].layer.name) .. "," .. tostring(celsArr[2].layer.name)))

  local celsDup = host:resolveCels(spr, 1, { "base", "base" })
  check("重复层名去重", celsDup ~= nil and #celsDup == 1, celsDup and #celsDup)

  local nilCels, missingErr = host:resolveCels(spr, 1, { "nope" })
  check("层名写错返回 nil, err（不抛）", nilCels == nil and type(missingErr) == "string")
  check("层名写错的错误里列出本文档的层名",
    tostring(missingErr):find("base", 1, true) ~= nil
      and tostring(missingErr):find("detail", 1, true) ~= nil
      and tostring(missingErr):find("no layer named", 1, true) ~= nil, missingErr)

  local stubHost = hostMod.new({ activeSprite = nil, fs = app.fs }, {})
  local nilCels2, noDocErr = stubHost:resolveCels(nil, 1, "all")
  check("没有文档时返回可读错误", nilCels2 == nil and tostring(noDocErr):find("no document", 1, true) ~= nil, noDocErr)
  check("没有文档时 active() 返回 nil", stubHost:active() == nil)

  local act = host:active()
  -- 命名规则与 v0.5.9 一致：有文件名就用文件名，没有才 "(未命名)"
  local expectedName = "(未命名)"
  if spr.filename ~= "" then expectedName = app.fs.fileName(spr.filename) end
  check("active() 给出 sprite/frame/name",
    act ~= nil and act.sprite == spr and act.frame == 1 and act.name == expectedName,
    act and (tostring(act.frame) .. " " .. tostring(act.name)))

  local nameless = hostMod.new({ activeSprite = { filename = "" }, fs = app.fs }, {})
  local namelessAct = nameless:active()
  check("没有文件名时显示 (未命名)", namelessAct ~= nil and namelessAct.name == "(未命名)",
    namelessAct and namelessAct.name)
  check("active() 的 document 与 sprite 是同一个对象", act.document == spr)

  local layersBefore = #spr.layers
  local okApply, applyErr = host:apply("kernel test", function() spr:newLayer() end)
  check("apply 在事务里执行并返回 true", okApply == true and #spr.layers == layersBefore + 1, applyErr)
  local okApply2, applyErr2 = host:apply("boom", function() error("inside transaction") end)
  check("apply 内抛错转成 false, err 不崩",
    okApply2 == false and tostring(applyErr2):find("inside transaction", 1, true) ~= nil, applyErr2)

  app.activeLayer = spr.layers[1]
  local targetCel = app.activeCel
  targetCel.image:clear(Rectangle(0, 0, 8, 8), Color(255, 0, 0))
  local changed = host:drawCells({ targetCel }, function(scratch)
    scratch:clear(Rectangle(0, 0, 8, 8), Color(0, 255, 0))
    return 4
  end)
  check("drawCells 返回改变计数", changed == 4, changed)
  check("drawCells 真的写回像素", targetCel.image:getPixel(0, 0) == Color(0, 255, 0).rgbaPixel,
    targetCel.image:getPixel(0, 0))

  local noVer, verErr = host:versions()
  check("versions 未注入时给可读错误", noVer == nil and tostring(verErr):find("versions", 1, true) ~= nil, verErr)
  local fakeVersions = { list = function() return {} end }
  local host2 = hostMod.new(app, { versions = fakeVersions })
  check("versions 注入后原样返回（接口不变）", host2:versions() == fakeVersions)
  local reported = nil
  local host3 = hostMod.new(app, { notify = function(msg, tone) reported = { msg = msg, tone = tone } end })
  host3:notify("hello", "ok")
  check("notify 走注入的 UI", reported ~= nil and reported.msg == "hello" and reported.tone == "ok",
    reported and reported.msg)
end

-- ----------------------------------------------------------------- dsl
print("== kernel.dsl: 沙箱 ==")
do
  local envNoPerm = dslMod.env(nil)
  check("无 perms 时 env 里没有 io", envNoPerm.io == nil)
  check("无 perms 时 env 里没有 os", envNoPerm.os == nil)
  check("debug 永不开放", envNoPerm.debug == nil and dslMod.env({ "io", "os" }).debug == nil)
  check("无 perms 时包/require 不可见",
    envNoPerm.package == nil and envNoPerm.require == nil)

  local ioProbe = dslMod.load("return type(io)", "probe-io")
  check("沙箱内 type(io) == nil", ioProbe ~= nil and ioProbe() == "nil", ioProbe and ioProbe())
  local osProbe = dslMod.load("return type(os)", "probe-os")
  check("沙箱内 type(os) == nil", osProbe ~= nil and osProbe() == "nil", osProbe and osProbe())
  local reqProbe = dslMod.load("return type(require)", "probe-require")
  check("沙箱内 type(require) == nil", reqProbe ~= nil and reqProbe() == "nil", reqProbe and reqProbe())

  local nilFn, synErr = dslMod.load("return +", "syntax-bad")
  check("语法错返回 nil, err（不抛）", nilFn == nil and type(synErr) == "string" and #synErr > 0, synErr)
  check("语法错的 err 里带 chunk 名", tostring(synErr):find("syntax%-bad") ~= nil, synErr)

  local okCall, callErr = pcall(dslMod.load, "return +", "syntax-bad")
  check("dsl.load 本身不会把错误抛出去", okCall == true and callErr == nil, callErr)

  local nilFn2, typeErr = dslMod.load(42, "not-a-string")
  check("src 不是字符串时返回 nil, err", nilFn2 == nil and tostring(typeErr):find("string", 1, true) ~= nil, typeErr)

  local ioFilePath = tempDir("dsl") .. "/io-probe.txt"
  local withIo = dslMod.load(
    "local f = io.open(\"" .. ioFilePath:gsub("\\", "/") .. "\", \"w\") if not f then return nil end f:write(\"hello\") f:close() return true",
    "probe-io-perm", { "io" })
  check("perms 含 io 时沙箱里 io.open 可用", withIo ~= nil and withIo() == true, withIo)
  check("沙箱真的写下了文件", readFile(ioFilePath) == "hello", readFile(ioFilePath))

  local osWithPerm = dslMod.load("return (type(os) == 'table' and type(os.time) == 'function') and type(os.execute) or 'no'",
    "probe-os-perm", { "os" })
  check("perms 含 os 时只给读时钟的半个 os（无 execute）",
    osWithPerm ~= nil and osWithPerm() == "nil", osWithPerm and osWithPerm())

  local libsProbe = dslMod.load("return type(string.format) .. ',' .. type(table.concat) .. ',' .. type(math.floor) .. ',' .. type(utf8.len)",
    "probe-libs")
  check("沙箱内有 string/table/math/utf8", libsProbe() == "function,function,function,function", libsProbe())

  local filePath = tempDir("dslfile") .. "/mod.lua"
  writeFile(filePath, "local a = 1\r\nlocal b = 2\r\nreturn a + b\r\n")
  local fnFromFile, fileErr = dslMod.loadFile(filePath, "mod-from-file")
  check("loadFile 能载入带 CRLF 的文件", fnFromFile ~= nil and fnFromFile() == 3, fileErr)
  local nilFile, missingFileErr = dslMod.loadFile(tempDir("dslfile") .. "/nope.lua", "missing")
  check("loadFile 读不到文件时返回 nil, err", nilFile == nil and tostring(missingFileErr):find("cannot read", 1, true) ~= nil, missingFileErr)
end

-- ------------------------------- ledger 的启停/回滚发总线事件（供入口撤算子）
print("== kernel.ledger: 启停/回滚发总线事件 ==")
do
  local userDir = tempDir("eventpacks")
  local src = tempDir("eventsrc") .. "/evpack"
  pcall(function() app.fs.makeAllDirectories(src) end)
  writeFile(src .. "/manifest.json", '{"id":"evpack","name":"E","version":"1.0.0","api":1,"permissions":[]}')
  writeFile(src .. "/main.lua", "return function() end")

  local kEv = kernelInit.new({
    app = app,
    ledger = { dir = tempDir("kernel-events"), fs = app.fs, packsDirs = { userDir } },
  })
  local seen = {}
  kEv.bus:on("pack.disabled", function(p) seen[#seen + 1] = "disabled:" .. tostring(p.id) end)
  kEv.bus:on("pack.rolledback", function(p) seen[#seen + 1] = "rolledback:" .. tostring(p.id) end)

  kEv.ledger:install(src)
  kEv.ledger:install(src)          -- 第二次安装才留下 bak-1
  kEv.ledger:disable("evpack")
  check("disable 在总线上发 pack.disabled（账本不认识 agent）",
    seen[1] == "disabled:evpack", seen[1])
  kEv.ledger:rollback("evpack")
  check("rollback 在总线上发 pack.rolledback", seen[2] == "rolledback:evpack", seen[2])
end

-- ------------------------------------------------ dsl.runBounded（沙箱限时）
print("== kernel.dsl: runBounded ==")
do
  local okFast, fastVal = dslMod.runBounded(function() return 42 end, 500)
  check("正常函数不被误杀", okFast == true and fastVal == 42, tostring(fastVal))

  local okErr, errVal = dslMod.runBounded(function() error("boom") end, 500)
  check("非超时错误原样透传", okErr == nil and tostring(errVal):find("boom", 1, true) ~= nil, errVal)

  local t0 = os.clock()
  local okLoop, loopErr = dslMod.runBounded(function() while true do end end, 120)
  local elapsedMs = (os.clock() - t0) * 1000
  check("死循环在预算内被掐断且返回可读错误",
    okLoop == nil and tostring(loopErr):find("sandbox timeout after 120 ms", 1, true) ~= nil, loopErr)
  check("掐断时间贴着预算（不是等到天荒地老）", elapsedMs < 620, math.floor(elapsedMs))

  check("结束后不残留 hook", debug.gethook() == nil)
  local sum = 0
  local hostStart = os.clock()
  for i = 1, 200000 do sum = sum + i end
  local hostMs = (os.clock() - hostStart) * 1000
  check("宿主自身循环不受残留 hook 干扰", sum > 0 and hostMs < 1000, math.floor(hostMs))

  local nestedInner = nil
  local okNested, nestedVal = dslMod.runBounded(function()
    local okIn, vIn = dslMod.runBounded(function() return "inner" end, 500)
    nestedInner = tostring(okIn) .. ":" .. tostring(vIn)
    return "outer"
  end, 500)
  check("嵌套限步互不干扰（内层结束后外层恢复）",
    okNested == true and nestedVal == "outer" and nestedInner == "true:inner", nestedInner)
end

-- -------------------------------------------------------------- ledger
print("== kernel.ledger ==")
do
  local dir = tempDir("journal")
  local l = ledgerMod.new({ dir = dir, fs = app.fs, maxLines = 5 })
  l:journal({ event = "test.one", id = "core" })
  l:journal({ event = "test.two", id = "ops" })
  local text = readFile(dir .. "/journal.jsonl")
  check("journal 落盘且一行一条", countLines(text) == 2, countLines(text))
  local firstLine = (text or ""):match("[^\n]+")
  local decodeOk, decoded = pcall(function() return json.decode(firstLine) end)
  check("journal 每行是合法 JSON", decodeOk and decoded ~= nil, firstLine)
  check("journal 记录里带 ts 与 event", decodeOk and decoded.ts ~= nil and tostring(decoded.event) == "test.one",
    decodeOk and tostring(decoded.event))

  for i = 1, 8 do l:journal({ event = "filler", n = i }) end
  check("内存环形上限生效", #l.events == 5, #l.events)
  check("journal 文件也不超过上限", countLines(readFile(dir .. "/journal.jsonl")) <= 5,
    countLines(readFile(dir .. "/journal.jsonl")))
  check("tail 给最后 n 条", #l:tail(3) == 3, #l:tail(3))

  local scanner = ledgerMod.new({ dir = tempDir("scan"), fs = app.fs })
  local packs, scanErrors = scanner:scan({ EXT .. "/packs/builtin" })
  check("scan 发现 builtin 两个包", #packs == 2, #packs)
  check("scan 没有报错", #scanErrors == 0, scanErrors[1] and scanErrors[1].err)
  check("包 id 是 core 与 ops", packs[1].id == "core" and packs[2].id == "ops",
    tostring(packs[1] and packs[1].id) .. "," .. tostring(packs[2] and packs[2].id))
  check("manifest 的 permissions/requires 被解析", type(packs[1].permissions) == "table"
    and #packs[1].permissions == 0 and type(packs[2].requires) == "table" and packs[2].requires[1] == "core",
    packs[2].requires[1])
  check("manifest 的操作清单被解析", #packs[2].ops == 10, #packs[2].ops)
  check("tests.lua 存在性被识别", packs[1].hasTests == true and packs[2].hasTests == true)

  local badRoot = tempDir("badscan")
  local function makePack(name, manifest, mainLua)
    local d = badRoot .. "/" .. name
    pcall(function() app.fs.makeAllDirectories(d) end)
    writeFile(d .. "/manifest.json", manifest)
    if mainLua then writeFile(d .. "/main.lua", mainLua) end
    return d
  end
  makePack("api2", '{"id":"api2","name":"A","version":"1.0.0","api":2,"permissions":[]}', "return function() end")
  makePack("badperm", '{"id":"badperm","name":"B","version":"1.0.0","api":1,"permissions":["net"]}', "return function() end")
  makePack("nomain", '{"id":"nomain","name":"C","version":"1.0.0","api":1,"permissions":[]}', nil)
  local _, badErrors = scanner:scan({ badRoot })
  check("api 不符被拒并给可读理由", #badErrors == 3, #badErrors)
  local joined = {}
  for _, e in ipairs(badErrors) do joined[#joined + 1] = tostring(e.id) .. "=" .. tostring(e.err) end
  local blob = table.concat(joined, " | ")
  check("错误里提到 api 版本", blob:find("unsupported api 2", 1, true) ~= nil, blob)
  check("错误里提到权限闭集", blob:find("closed set", 1, true) ~= nil, blob)
  check("错误里提到缺 main.lua", blob:find("missing main.lua", 1, true) ~= nil, blob)

  local userDir = tempDir("userpacks")
  local srcPack = tempDir("srcpack") .. "/mypack"
  pcall(function() app.fs.makeAllDirectories(srcPack) end)
  writeFile(srcPack .. "/manifest.json", '{"id":"mypack","name":"M","version":"1.0.0","api":1,"permissions":[]}')
  writeFile(srcPack .. "/main.lua", "return function() end")
  local installer = ledgerMod.new({ dir = tempDir("install-journal"), fs = app.fs, packsDirs = { userDir } })
  local okInstall, installErr = installer:install(srcPack)
  check("install 复制成功", okInstall == true, installErr)
  local installed = installer:scan()
  check("install 后可被 scan 发现", #installed == 1 and installed[1].id == "mypack", #installed)
  check("install 后的版本是 1.0.0", installed[1] and installed[1].version == "1.0.0",
    installed[1] and installed[1].version)

  writeFile(srcPack .. "/manifest.json", '{"id":"mypack","name":"M","version":"1.1.0","api":1,"permissions":[]}')
  installer:install(srcPack)
  check("二次安装留下备份目录", app.fs.isDirectory(userDir .. "/mypack.bak-1"))
  check("二次安装后版本是 1.1.0", (installer:scan())[1].version == "1.1.0",
    (installer:scan())[1].version)
  check("rollback 成功", installer:rollback("mypack") == true)
  check("rollback 后回到 1.0.0", (installer:scan())[1].version == "1.0.0",
    (installer:scan())[1].version)
  local okRollbackAgain = installer:rollback("mypack")
  check("没有备份时 rollback 给可读理由", okRollbackAgain == false)

  check("disable 记进状态文件", installer:disable("mypack") == true and installer:isEnabled("mypack") == false)
  check("enable 恢复", installer:enable("mypack") == true and installer:isEnabled("mypack") == true)

  local h = ledgerMod.new({ dir = tempDir("health"), fs = app.fs })
  h:recordCall("ops", 10)
  h:recordCall("ops", 30, "boom")
  local health = h:health()
  check("health 记录 calls/fails/lastErr",
    health["ops"].calls == 2 and health["ops"].fails == 1 and health["ops"].lastErr == "boom",
    tostring(health["ops"].calls) .. "/" .. tostring(health["ops"].fails))
  check("health 的 msAvg 是有限数", health["ops"].msAvg > 0 and health["ops"].msAvg < 1000,
    health["ops"].msAvg)
end

-- ------------------------------------------------------ init + packs
print("== kernel.init + 内置能力包 ==")
do
  -- 沙箱里没有 require：核心模块走 shared 交进去（与 main.lua 同一条路）
  local shared = { ops = require("lib.ops") }
  local k, kerr = kernelInit.new({
    app = app,
    shared = shared,
    ledger = { dir = tempDir("kernel"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin" } },
  })
  check("K.new 返回内核实例", type(k) == "table" and k.version ~= nil, kerr)
  check("六件套齐全（bus/registry/host/dsl/ledger/version）",
    k.bus ~= nil and k.registry ~= nil and k.host ~= nil and k.dsl ~= nil and k.ledger ~= nil and k.version ~= nil)

  local packEvents = {}
  k.bus:on("pack.changed", function(p) packEvents[#packEvents + 1] = p.id .. ":" .. tostring(p.action) end)

  local packs, packErrors = kernelInit.mountPacks(k, {})
  check("装载了 core 与 ops", #packs == 2, #packs)
  check("没有包加载错误", #packErrors == 0, packErrors[1] and packErrors[1].err)
  check("core 注册了 7 个 view", #k.registry:list("view") == 7, #k.registry:list("view"))
  check("ops 注册了 10 个 op", #k.registry:list("op") == 10, #k.registry:list("op"))
  check("core 注册了两个内建 action",
    k.registry:get("action", "core.health") ~= nil and k.registry:get("action", "core.journal") ~= nil)
  check("每个装载成功的包都发过 pack.changed",
    #packEvents == 2 and packEvents[1] == "core:loaded" and packEvents[2] == "ops:loaded",
    table.concat(packEvents, ","))
  check("装载事件写进了 journal",
    (function()
      for _, ev in ipairs(k.ledger:tail(20)) do
        if ev.event == "pack.loaded" and ev.id == "ops" then return true end
      end
      return false
    end)())

  for _, pack in ipairs(packs) do
    local res = kernelInit.runPackTests(k, pack)
    -- ok 是护栏 #2 的判据：真断言过、且没有失败用例
    check("包自测全绿且真的断言过: " .. pack.id,
      res.ok == true and res.failed == 0 and res.asserts > 0,
      res.reason or (res.results[1] and res.results[1].err))
  end

  -- 工作台的接线：core 包的 view.mount 必须把渲染交给注入的 renderers[id]
  -- （T2 的 lib/views/* 由 main.lua 在 init() 里 require 完再交进来）
  local registered = {}
  local k3 = kernelInit.new({
    app = app,
    shared = shared,
    ledger = { dir = tempDir("kernel3"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin" } },
  })
  kernelInit.mountPacks(k3, {
    renderers = {
      console = function(ctx) registered[#registered + 1] = "console"; return { id = "console", real = true } end,
    },
  })
  local consoleSpec = k3.registry:get("view", "console")
  local mountedView = consoleSpec and consoleSpec.mount({})
  check("view.mount 把渲染转交给注入的 renderers",
    mountedView ~= nil and mountedView.real == true and registered[1] == "console",
    mountedView and tostring(mountedView.real))
  local canvasSpec = k3.registry:get("view", "canvas")
  check("没有渲染器的视图退回占位（不崩）",
    canvasSpec and canvasSpec.mount({}).placeholder == true)

  local brokenRoot = tempDir("brokenpacks")
  local brokenDir = brokenRoot .. "/broken"
  pcall(function() app.fs.makeAllDirectories(brokenDir) end)
  writeFile(brokenDir .. "/manifest.json", '{"id":"broken","name":"B","version":"1.0.0","api":1,"permissions":[]}')
  writeFile(brokenDir .. "/main.lua", "error('boom from pack')")
  local k2 = kernelInit.new({
    app = app,
    shared = shared,
    ledger = { dir = tempDir("kernel2"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin", brokenRoot } },
  })
  local packs2, errors2 = kernelInit.mountPacks(k2, {})
  check("坏包不拖累好包", #packs2 == 2 and #errors2 == 1, #errors2)
  local brokenHealth = k2.ledger:health()["broken"]
  check("坏包的 lastErr 可读并含原始原因",
    brokenHealth ~= nil and tostring(brokenHealth.lastErr):find("boom from pack", 1, true) ~= nil,
    brokenHealth and brokenHealth.lastErr)
  check("坏包之后 registry 依然只有好包注册的内容", #k2.registry:list("view") == 7,
    #k2.registry:list("view"))

  local savePath = package.path
  local saveBus = package.loaded["kernel.bus"]
  package.loaded["kernel.bus"] = nil
  package.path = EXT .. "/__no_such_dir__/?.lua"
  local nilKernel, loadErr = kernelInit.new({ app = app })
  package.path = savePath
  package.loaded["kernel.bus"] = saveBus
  check("内核模块加载失败返回可读错误（不抛）",
    nilKernel == nil and tostring(loadErr):find("kernel.bus.lua failed to load", 1, true) ~= nil, loadErr)
end

-- --------------------------------------------------- 薄入口 main.lua
print("== extension/main.lua 薄入口 ==")
do
  local cmds = {}
  local fakePlugin = {
    path = EXT,
    newCommand = function(self, spec) cmds[#cmds + 1] = spec end,
  }
  local chunk = assert(loadfile(EXT .. "/main.lua"))
  chunk()
  check("main.lua 能作为脚本加载", type(init) == "function" and type(exit) == "function")
  local okInit, initErr = pcall(init, fakePlugin)
  check("init(plugin) 不抛错", okInit, initErr)
  check("注册了 6 个命令", #cmds == 6, #cmds)

  local ids = {}
  for _, c in ipairs(cmds) do ids[#ids + 1] = tostring(c.id) end
  table.sort(ids)
  local want = {
    "ai_pixel_copilot_menu", "ai_pixel_copilot_open", "ai_pixel_copilot_palette",
    "ai_pixel_copilot_rollback", "ai_pixel_copilot_settings", "ai_pixel_copilot_snapshot",
  }
  check("6 个命令 id 与 v0.5.9 逐字一致", table.concat(ids, ",") == table.concat(want, ","),
    table.concat(ids, ","))

  local menuCount, openGroup = 0, nil
  for _, c in ipairs(cmds) do
    if c.group ~= nil then
      menuCount = menuCount + 1
      if c.id == "ai_pixel_copilot_open" then openGroup = c.group end
    end
  end
  check("菜单只挂 open 一条", menuCount == 1, menuCount)
  check("open 挂在 file_scripts 菜单", openGroup == "file_scripts", openGroup)

  local allHaveOnclick = true
  for _, c in ipairs(cmds) do
    if type(c.onclick) ~= "function" then allHaveOnclick = false end
  end
  check("每个命令都有 onclick", allHaveOnclick)

  local okExit = pcall(exit, fakePlugin)
  check("exit(plugin) 不抛错", okExit)
end

-- ------------------------------------- 沙箱限时在装载与包自测上真的生效
print("== 沙箱限时：能力包装载与包自测 ==")
do
  local shared = { ops = require("lib.ops") }
  local loopRoot = tempDir("looppacks")

  local function makePack(name, manifest, mainLua, testsLua)
    local d = loopRoot .. "/" .. name
    pcall(function() app.fs.makeAllDirectories(d) end)
    writeFile(d .. "/manifest.json", manifest)
    writeFile(d .. "/main.lua", mainLua)
    if testsLua then writeFile(d .. "/tests.lua", testsLua) end
    return d
  end

  makePack("loop", '{"id":"loop","name":"L","version":"1.0.0","api":1,"permissions":[]}',
    "return function() while true do end end", nil)
  makePack("looptests", '{"id":"looptests","name":"LT","version":"1.0.0","api":1,"permissions":[]}',
    "return function() end",
    "return { { name = '死循环自测', run = function() while true do end end } }")

  local kLoop = kernelInit.new({
    app = app,
    sandboxMs = 120,
    shared = shared,
    ledger = { dir = tempDir("kernel-loop"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin", loopRoot } },
  })
  local loopStart = os.clock()
  local packsLoop, errorsLoop = kernelInit.mountPacks(kLoop, {})
  local elapsed = (os.clock() - loopStart) * 1000

  check("死循环包装载失败但好包照常装上", #packsLoop == 3, #packsLoop)
  check("装载错误里是可读的超时原因",
    #errorsLoop == 1 and tostring(errorsLoop[1].err):find("sandbox timeout after 120 ms", 1, true) ~= nil,
    errorsLoop[1] and errorsLoop[1].err)
  check("装载没有卡死（耗时贴着预算）", elapsed < 1500, math.floor(elapsed))
  check("超时包进账本 health 的 lastErr",
    kLoop.ledger:health()["loop"] ~= nil
      and tostring(kLoop.ledger:health()["loop"].lastErr):find("sandbox timeout", 1, true) ~= nil,
    kLoop.ledger:health()["loop"] and kLoop.ledger:health()["loop"].lastErr)

  local ltPack = nil
  for _, p in ipairs(kLoop.packs) do if p.id == "looptests" then ltPack = p end end
  check("自测用的包被正常装载", ltPack ~= nil)
  if ltPack then
    local res = kernelInit.runPackTests(kLoop, ltPack)
    check("tests.lua 里的死循环被掐断并报 failed",
      res.failed == 1 and tostring(res.results[1].err):find("sandbox timeout after 120 ms", 1, true) ~= nil,
      res.results[1] and res.results[1].err)
  end
end

-- ------------------------------------- 护栏 #2：必须自测（数真实断言）
print("== 护栏 #2：包自测必须真的断言过 ==")
do
  local root = tempDir("packselftest")
  local kT = kernelInit.new({
    app = app,
    ledger = { dir = tempDir("kernel-packtests"), fs = app.fs },
  })

  local function testPack(id, testsSrc)
    local d = root .. "/" .. id
    pcall(function() app.fs.makeAllDirectories(d) end)
    writeFile(d .. "/main.lua", "return function() end")
    writeFile(d .. "/tests.lua", testsSrc)
    return { id = id, dir = d, permissions = {} }
  end

  local emptyRes = kernelInit.runPackTests(kT, testPack("emptytests", "return {}"))
  check("空 tests.lua（return {}）判为没验过",
    emptyRes.asserts == 0 and emptyRes.ok == false, emptyRes.reason)
  check("空 tests.lua 的理由可读",
    tostring(emptyRes.reason):find("ran 0 assertions", 1, true) ~= nil, emptyRes.reason)

  local noAssert = kernelInit.runPackTests(kT,
    testPack("noassert", "return { { name = 'nothing', run = function(t) end } }"))
  check("只写 run 不打断言：用例过了但判为没验过",
    noAssert.asserts == 0 and noAssert.passed == 1 and noAssert.ok == false,
    "asserts=" .. tostring(noAssert.asserts) .. " passed=" .. tostring(noAssert.passed))

  local good = kernelInit.runPackTests(kT,
    testPack("goodthree", "return { { name = 'three', run = function(t) t.ok(true, 'a') t.eq(1, 1, 'b') t.ok(2 > 1, 'c') end } }"))
  check("3 个真断言全过 → asserts==3 且 ok==true",
    good.asserts == 3 and good.failed == 0 and good.ok == true,
    "asserts=" .. tostring(good.asserts) .. " " .. tostring(good.reason))

  local mixed = kernelInit.runPackTests(kT,
    testPack("mixed", "return { { name = 'mix', run = function(t) t.ok(true, 'a') t.eq(1, 1, 'b') t.ok(false, 'third blew up') end } }"))
  check("2 过 1 挂 → failed==1、asserts==3、ok==false",
    mixed.asserts == 3 and mixed.failed == 1 and mixed.ok == false,
    "asserts=" .. tostring(mixed.asserts) .. " failed=" .. tostring(mixed.failed))
  check("挂掉的那条断言的消息被保留",
    tostring(mixed.results[1].err):find("third blew up", 1, true) ~= nil, mixed.results[1].err)

  local eqCase = kernelInit.runPackTests(kT,
    testPack("eqcount", "return { { name = 'eq', run = function(t) t.eq(2, 2, 'same') t.eq(1, 2, 'diff') end } }"))
  check("t.eq 成功与失败各计一次（asserts==2）",
    eqCase.asserts == 2 and eqCase.failed == 1 and eqCase.ok == false,
    "asserts=" .. tostring(eqCase.asserts))
  check("t.eq 失败的消息带上期望/实际值",
    tostring(eqCase.results[1].err):find("expected 2, got 1", 1, true) ~= nil, eqCase.results[1].err)
end

-- --------------------------------------- invoke：带预算的能力调用入口
print("== kernel.init: invoke（限时调用）==")
do
  local shared = { ops = require("lib.ops") }
  local kInv = kernelInit.new({
    app = app,
    sandboxMs = 500,
    shared = shared,
    ledger = { dir = tempDir("kernel-invoke"), fs = app.fs, packsDirs = { EXT .. "/packs/builtin" } },
  })
  kernelInit.mountPacks(kInv, {})

  -- 1) 真实 op：返回值正确（8x8 全红 -> 全绿 = 64 px）
  local sprInv = Sprite(8, 8, ColorMode.RGB)
  app.activeSprite = sprInv
  app.activeCel.image:clear(Rectangle(0, 0, 8, 8), Color(255, 0, 0))
  local okOp, opRes = kInv:invoke("op", "replace_color", kInv.host, { from = "#FF0000", to = "#00FF00" })
  check("invoke 正常 op 返回 (true, 报告)",
    okOp == true and type(opRes) == "table" and opRes.changed == 64, opRes and opRes.changed)
  check("invoke 的像素真的改了",
    app.activeCel.image:getPixel(0, 0) == Color(0, 255, 0).rgbaPixel,
    app.activeCel.image:getPixel(0, 0))

  -- 2) 死循环 op.run 被掐断
  kInv.registry:define("op", { name = "loop_op", run = function() while true do end end })
  local loopStart = os.clock()
  local okLoopOp, loopOpErr = kernelInit.invokeBounded(kInv, 120, "op", "loop_op")
  local loopMs = (os.clock() - loopStart) * 1000
  check("死循环的 op.run 被掐断且给可读超时错误",
    okLoopOp == nil and tostring(loopOpErr):find("sandbox timeout after 120 ms", 1, true) ~= nil, loopOpErr)
  check("掐断贴着预算（没把 UI 拖死）", loopMs < 620, math.floor(loopMs))

  -- 3) 未知 kind / id
  local okMiss, missErr = kInv:invoke("op", "no_such_op")
  check("invoke 未知 id 返回 nil, err",
    okMiss == nil and tostring(missErr):find("no op named no_such_op", 1, true) ~= nil, missErr)
  local okKind, kindErr = kInv:invoke("bogus", "whatever")
  check("invoke 未知 kind 返回 nil, err",
    okKind == nil and tostring(kindErr):find("no bogus named whatever", 1, true) ~= nil, kindErr)

  -- 4) 普通错误原样透传（不吞、不改写）
  kInv.registry:define("op", { name = "boom_op", run = function() error("kaboom from op") end })
  local okBoom, boomErr = kInv:invoke("op", "boom_op")
  check("invoke 原样透传普通错误",
    okBoom == nil and tostring(boomErr):find("kaboom from op", 1, true) ~= nil, boomErr)

  -- 5) 不留残余 hook
  check("invoke 之后不残留 hook", debug.gethook() == nil)

  -- 6) 嵌套 invoke 互不干扰
  kInv.registry:define("op", { name = "inner_op", run = function() return "inner" end })
  kInv.registry:define("op", {
    name = "outer_op",
    run = function()
      local okIn, vIn = kernelInit.invoke(kInv, "op", "inner_op")
      return tostring(okIn) .. ":" .. tostring(vIn)
    end,
  })
  local okNest, nestVal = kInv:invoke("op", "outer_op")
  check("嵌套 invoke 互不干扰（内层结束后外层恢复）",
    okNest == true and nestVal == "true:inner", nestVal)

  -- 7) 默认预算来自 kernel.sandboxMs（这里是 500ms）
  local okSmall, smallErr = kernelInit.invoke(kInv, "op", "loop_op")
  check("invoke 的默认预算跟着 kernel.sandboxMs（500ms）走",
    okSmall == nil and tostring(smallErr):find("sandbox timeout after 500 ms", 1, true) ~= nil, smallErr)
end

-- ------------------------------------------------ 冻结签名核对
print("== 冻结签名（docs/arch-v1.0.md §3）==")
do
  local bus = busMod.new()
  check("Bus.new() 无参可用", type(bus.on) == "function" and type(bus.emit) == "function"
    and type(bus.off) == "function" and type(bus.drain) == "function")

  local reg = registryMod.new()
  for _, name in ipairs({ "define", "get", "list", "remove", "kinds", "fingerprint" }) do
    check("Registry:" .. name .. " 存在", type(reg[name]) == "function")
  end

  local host = hostMod.new(app)
  for _, name in ipairs({ "active", "resolveCels", "apply", "drawCells", "openDocument",
                          "alert", "notify", "filePicker", "versions" }) do
    check("Host:" .. name .. " 存在", type(host[name]) == "function")
  end

  check("Dsl.load / loadFile / env 都存在",
    type(dslMod.load) == "function" and type(dslMod.loadFile) == "function" and type(dslMod.env) == "function")

  local stringLedger = ledgerMod.new(tempDir("sig-ledger"))
  check("Ledger.new(dir) 字符串形式可用（§3.6 的签名）",
    type(stringLedger.journal) == "function" and type(stringLedger.file) == "string")
  for _, name in ipairs({ "scan", "install", "enable", "disable", "rollback", "health", "journal" }) do
    check("Ledger:" .. name .. " 存在", type(stringLedger[name]) == "function")
  end
end

print(string.format("\n==== kernel_test: %d 通过, %d 失败 ====", passes, fails))
if fails > 0 then error(fails .. " 个断言失败") end
