-- kernel/init.lua -- 组装（§3）：把内核模块拼成一个实例，并负责装载能力包
-- 这里只做装配与容错：任何模块加载失败都返回可读错误，绝不让扩展崩掉。
local K = {}

K.version = "1.0.0"
K.API_VERSION = 1

local MODULE_NAMES = { "bus", "registry", "host", "dsl", "ledger" }

-- 能力包的单次执行预算。装载、注册、包自测都吃这一个数，可注入（kernel_test 用 120ms 测掐断）。
local DEFAULT_SANDBOX_MS = 2000

local function loadModules()
  local mods = {}
  for _, name in ipairs(MODULE_NAMES) do
    local ok, mod = pcall(require, "kernel." .. name)
    if not ok then
      return nil, string.format("kernel.%s.lua failed to load: %s", name, tostring(mod))
    end
    if type(mod) ~= "table" then
      return nil, string.format("kernel.%s.lua did not return a table", name)
    end
    mods[name] = mod
  end
  return mods
end

function K.new(opts)
  opts = opts or {}
  local mods, err = loadModules()
  if not mods then return nil, err end

  local bus = mods.bus.new()
  local registry = mods.registry.new({ bus = bus })
  local host = mods.host.new(opts.app, {
    versions = opts.versions,
    alert = opts.alert,
    notify = opts.notify,
    filePicker = opts.filePicker,
  })
  local ledgerOpts = opts.ledger or {}
  if ledgerOpts.bus == nil then
    -- 账本用总线发 pack.disabled / pack.rolledback；订阅方（main.lua）负责转给 agent，
    -- 账本因此不需要认识 agent。
    local copy = {}
    for k, v in pairs(ledgerOpts) do copy[k] = v end
    copy.bus = bus
    ledgerOpts = copy
  end
  local ledger = mods.ledger.new(ledgerOpts)

  -- 总线上的 handler 抛错也要进账本：内核里不能有第二个"日志去处"
  bus.journal = function(event) pcall(ledger.journal, ledger, event) end

  return {
    version = K.version,
    api = K.API_VERSION,
    modules = mods,
    bus = bus,
    registry = registry,
    host = host,
    dsl = mods.dsl,
    ledger = ledger,
    kit = opts.kit,
    -- 包可见的核心模块白名单（main.lua 填 { ops = ... }），空表即什么都不给
    shared = opts.shared or {},
    packs = {},
    packErrors = {},
    -- 包自测（tests.lua）要拿到自己那个 ctx，否则它没法断言注册结果
    packContexts = {},
    sandboxMs = tonumber(opts.sandboxMs) or DEFAULT_SANDBOX_MS,
    -- 实例上再挂一个同名方法，接线时 kernel:invoke(...) 与 K.invoke(kernel, ...) 都能用
    invoke = function(this, kind, id, ...) return K.invoke(this, kind, id, ...) end,
  }
end

local function packLog(kernel, pack)
  return function(fmt, ...)
    local text
    if select("#", ...) > 0 then
      local ok, formatted = pcall(string.format, fmt, ...)
      text = ok and formatted or tostring(fmt)
    else
      text = tostring(fmt)
    end
    kernel.ledger:journal({ event = "pack.log", id = pack.id, text = text })
    kernel.bus:emit("log", { id = pack.id, text = text })
  end
end

function K.loadPack(kernel, pack, opts)
  opts = opts or {}
  local ledger = kernel.ledger
  local budget = tonumber(opts.sandboxMs or kernel.sandboxMs) or DEFAULT_SANDBOX_MS

  local function fail(msg)
    local text = tostring(msg)
    ledger:markError(pack.id, text)
    kernel.bus:emit("pack.error", { id = pack.id, err = text })
    return false, text
  end

  local chunk, lerr = kernel.dsl.loadFile(pack.dir .. "/main.lua", "pack:" .. pack.id, pack.permissions)
  if not chunk then return fail(lerr) end

  -- 包代码一律限时执行：一个死循环包不许把 UI 线程带走（dsl.runBounded）
  local okChunk, factory = kernel.dsl.runBounded(chunk, budget)
  if not okChunk then return fail("main.lua threw: " .. tostring(factory)) end
  if type(factory) ~= "function" then
    return fail("main.lua must return function(ctx) end (got " .. type(factory) .. ")")
  end

  local ctx = {
    registry = kernel.registry,
    host = kernel.host,
    kit = opts.kit or kernel.kit,
    dsl = kernel.dsl,
    log = packLog(kernel, pack),
    kernel = kernel,
    pack = pack,
    renderers = opts.renderers,
    -- 沙箱里没有 require/package，核心模块只能显式交进去
    shared = opts.shared or kernel.shared,
  }

  kernel.packContexts[pack.id] = ctx

  local okCall, cerr = kernel.dsl.runBounded(factory, budget, ctx)
  if not okCall then return fail("pack main.lua failed: " .. tostring(cerr)) end

  -- manifest 是声明式契约：声明了却没注册，说明包自己没写完，得让 UI 看见
  local missing = {}
  local function missingOf(kind, id, label)
    if id == nil then return end
    if not kernel.registry:get(kind, tostring(id)) then
      missing[#missing + 1] = label .. " " .. tostring(id)
    end
  end
  for _, v in ipairs(pack.views or {}) do missingOf("view", v.id, "view") end
  for _, c in ipairs(pack.commands or {}) do missingOf("command", c.id, "command") end
  for _, o in ipairs(pack.ops or {}) do missingOf("op", o.name, "op") end
  if #missing > 0 then
    local msg = "manifest declares but nothing registered: " .. table.concat(missing, ", ")
    ledger:journal({ event = "pack.incomplete", id = pack.id, err = msg })
    kernel.bus:emit("log", { id = pack.id, text = msg })
  end

  ledger:recordCall(pack.id, 0, nil)
  ledger:journal({ event = "pack.loaded", id = pack.id, version = pack.version, dir = pack.dir })
  kernel.bus:emit("pack.changed", { id = pack.id, action = "loaded" })
  return true, pack.id
end

function K.mountPacks(kernel, opts)
  opts = opts or {}
  local packs, errors = kernel.ledger:scan(opts.dirs)
  for _, e in ipairs(errors) do
    kernel.packErrors[#kernel.packErrors + 1] = e
    kernel.ledger:markError(tostring(e.id), e.err)
    kernel.bus:emit("pack.error", e)
  end

  for _, pack in ipairs(packs) do
    if kernel.ledger:isEnabled(pack.id) then
      local ok, err = K.loadPack(kernel, pack, opts)
      if ok then
        kernel.packs[#kernel.packs + 1] = pack
      else
        kernel.packErrors[#kernel.packErrors + 1] = { id = pack.id, err = tostring(err) }
      end
    else
      kernel.ledger:journal({ event = "pack.skipped", id = pack.id, reason = "disabled" })
    end
  end
  return kernel.packs, kernel.packErrors
end

-- 能力包自测跑法（packs/<id>/tests.lua）：返回 { {name=..., run=function(t) end} }
-- t 只给三个方法，够写断言、也不给包任何能力。
--
-- 判定看的是【真实执行过的断言数】，不是用例数：护栏 #2「必须自测」如果只数用例，
-- 一个 run=function(t) end 的空用例就能过闸，return {} 更是连闸都没过却报 0 失败 ——
-- 那这条护栏等于不存在。所以 t.ok/t.eq 每被真调一次就 +1，asserts == 0 一律判没验过。
function K.runPackTests(kernel, pack, opts)
  opts = opts or {}
  local budget = tonumber(opts.sandboxMs or kernel.sandboxMs) or DEFAULT_SANDBOX_MS
  local out = { passed = 0, failed = 0, asserts = 0, ok = false, reason = nil, results = {} }

  local function finish()
    if out.failed > 0 then
      out.ok = false
      out.reason = string.format("pack %s: %d of %d case(s) failed (%d assertion(s) ran)",
        tostring(pack.id), out.failed, out.passed + out.failed, out.asserts)
    elseif out.asserts == 0 then
      out.ok = false
      out.reason = string.format("pack %s claims tests but ran 0 assertions", tostring(pack.id))
    else
      out.ok = true
      out.reason = nil
    end
    return out
  end

  local chunk, lerr = kernel.dsl.loadFile(pack.dir .. "/tests.lua", "pack-tests:" .. pack.id, pack.permissions)
  if not chunk then
    out.results[#out.results + 1] = { name = "(load)", ok = false, err = tostring(lerr) }
    out.failed = out.failed + 1
    out.reason = string.format("pack %s: tests.lua failed to load: %s", tostring(pack.id), tostring(lerr))
    return out
  end

  -- 包自测也吃同一个预算：tests.lua 里写个死循环同样不许卡死 UI
  local okRun, cases = kernel.dsl.runBounded(chunk, budget)
  if not okRun or type(cases) ~= "table" then
    out.results[#out.results + 1] = { name = "(load)", ok = false, err = tostring(cases) }
    out.failed = out.failed + 1
    out.reason = string.format("pack %s: tests.lua did not return a case list: %s",
      tostring(pack.id), tostring(cases))
    return out
  end

  local t = {
    ctx = opts.ctx or kernel.packContexts[pack.id],
    ok = function(cond, msg)
      out.asserts = out.asserts + 1      -- 失败的断言也算执行过
      if not cond then error(msg or "assertion failed", 2) end
    end,
    eq = function(actual, expected, msg)
      out.asserts = out.asserts + 1
      if actual ~= expected then
        error(string.format("%s (expected %s, got %s)", msg or "not equal",
          tostring(expected), tostring(actual)), 2)
      end
    end,
    note = function() end,
  }

  for _, case in ipairs(cases) do
    local name = tostring(case.name or "(unnamed)")
    local okCase, err = kernel.dsl.runBounded(case.run or function() error("case has no run") end, budget, t)
    out.results[#out.results + 1] = { name = name, ok = okCase, err = okCase and nil or tostring(err) }
    if okCase then out.passed = out.passed + 1 else out.failed = out.failed + 1 end
  end
  return finish()
end

-- ---- 限时调用入口 -------------------------------------------------------
-- 为什么要有它：能力包注册的 op/action 被视图或 agent 直接调用时没有任何预算，
-- 一个死循环的 run() 照样能把 UI 线程带走 —— 那等于「模型能写算子」这件事有毒。
-- 这里只提供入口：不改 registry 的 API，也不改任何调用点（接线在合流时统一做）。
-- 返回与 dsl.runBounded 一致：(true, run 的返回值) 成功；(nil, err) 失败/超时。
function K.invokeBounded(kernel, budget, kind, id, ...)
  if type(kernel) ~= "table" or not kernel.registry then return nil, "invoke: kernel is required" end
  kind = tostring(kind)
  local spec = kernel.registry:get(kind, tostring(id))
  if not spec or type(spec.run) ~= "function" then
    return nil, string.format("no %s named %s", kind, tostring(id))
  end
  budget = tonumber(budget) or tonumber(kernel.sandboxMs) or DEFAULT_SANDBOX_MS
  return kernel.dsl.runBounded(spec.run, budget, ...)
end

function K.invoke(kernel, kind, id, ...)
  return K.invokeBounded(kernel, kernel and kernel.sandboxMs, kind, id, ...)
end

return K
