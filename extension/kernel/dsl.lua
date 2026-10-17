-- kernel/dsl.lua -- 声明的受限沙箱（§3.5）
-- load(src, "@"..name, "t", env) 已在 Aseprite 1.3.18.6-dev / Lua 5.4 上实测可用
-- （tests/lua/_kernel_probe.lua: load_env=42）。沙箱里的任何错都转成 nil, err，
-- 绝不冒泡到 UI —— 一个写歪的能力包不该让面板炸掉。
local Dsl = {}

-- 白名单：debug / package / require 永不开放（debug 能拿到寄存器，等于没有沙箱）
local BASE_NAMES = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "print",
  "rawequal", "rawget", "rawlen", "rawset", "select", "setmetatable",
  "getmetatable", "tonumber", "tostring", "type", "xpcall", "_VERSION",
}

-- 库要拷贝：直接把全局 string/table 交出去，包就能改掉内核自己用的库
local function copyLib(name)
  local src = _G[name]
  local out = {}
  if type(src) == "table" then
    for k, v in pairs(src) do out[k] = v end
  end
  return out
end

-- os 只给"读"的那半边：execute/exit/remove/rename 会绕过 permissions 的语义
local OS_ALLOWED = { "clock", "date", "difftime", "getenv", "time", "tmpname" }

local function osLib()
  local out = {}
  for _, k in ipairs(OS_ALLOWED) do out[k] = _G.os and _G.os[k] or nil end
  return out
end

local function permSet(perms)
  local set = {}
  if perms == nil then return set end
  if type(perms) == "string" then
    set[perms] = true
  elseif type(perms) == "table" then
    for _, p in ipairs(perms) do
      if type(p) == "string" then set[p] = true end
    end
  end
  return set
end

function Dsl.env(perms)
  local env = {}
  for _, name in ipairs(BASE_NAMES) do env[name] = _G[name] end
  env.string = copyLib("string")
  env.table = copyLib("table")
  env.math = copyLib("math")
  env.utf8 = copyLib("utf8")
  env.coroutine = copyLib("coroutine")

  local set = permSet(perms)
  if set.io then env.io = copyLib("io") end
  if set.os then env.os = osLib() end
  return env
end

function Dsl.load(src, name, perms)
  if type(src) ~= "string" then return nil, "dsl.load: src must be a string" end
  local chunkName = "@" .. tostring(name or "chunk")
  -- load 失败时返回 nil, 错误文本是【第二个】返回值：只接两个变量会把错误文本吞掉
  local ok, fn, loadErr = pcall(load, src, chunkName, "t", Dsl.env(perms))
  if not ok then return nil, tostring(fn) end
  if type(fn) ~= "function" then return nil, tostring(loadErr) end
  return fn
end

function Dsl.loadFile(path, name, perms)
  if type(path) ~= "string" or path == "" then return nil, "dsl.loadFile: path is required" end
  local f, openErr = io.open(path, "rb")
  if not f then return nil, "cannot read " .. path .. ": " .. tostring(openErr) end
  local src = f:read("*a")
  f:close()
  if type(src) ~= "string" then return nil, "cannot read " .. path end
  -- 归一化 CRLF：这个 Lua 的词法器只把 \n 当换行，带 \r 的多行字面量会报 unfinished string
  src = src:gsub("\r\n", "\n"):gsub("\r", "\n")
  return Dsl.load(src, name or path, perms)
end

local DEFAULT_BUDGET_MS = 2000

-- 数指令的粒度：1 太贵（每次 VM 指令都回调），太大又会让掐断变得迟钝。
-- 1000 条一次 + 一次 os.clock（微秒级）在实测里对正常包没有可感开销。
local HOOK_STEP = 1000

local function nowMs()
  -- os.clock 是 CPU 时间：失控的沙箱是纯 CPU 死循环，用它不会被系统时钟跳变或
  -- 挂起骗到（那会让"预算"在两个方向上都不准）。
  return os.clock() * 1000
end

-- 限时执行。为什么必须有它：一个死循环能力包会卡死 Aseprite 的 UI 线程 ——
-- 那就把"自扩展"变成了"自毁"。所以能力包的装载与自测一律走这里。
-- 返回：(true, fn 的第一个返回值) 成功；(nil, err) 失败（含超时）。
function Dsl.runBounded(fn, ms, ...)
  if type(fn) ~= "function" then return nil, "runBounded: fn must be a function" end
  local budget = tonumber(ms) or DEFAULT_BUDGET_MS
  if budget <= 0 then budget = DEFAULT_BUDGET_MS end
  local budgetText = string.format("sandbox timeout after %d ms", math.floor(budget))

  if type(debug) ~= "table" or type(debug.sethook) ~= "function" then
    -- 没有 debug 库就没有限步手段。照样执行，但绝不假装"已受保护"。
    local ok, result = pcall(fn, ...)
    if not ok then return nil, tostring(result) end
    return true, result
  end

  local deadline = nowMs() + budget
  local timedOut = false
  local function hook()
    if nowMs() > deadline then
      timedOut = true
      -- level 0：错误不带 dsl.lua 的内部栈位置，调用方看到的是"这个包超时了"
      error(budgetText, 0)
    end
  end

  -- 保存并恢复外层 hook：装载时会嵌套（包加载 -> 包自测），内层不能把外层的限步洗掉
  local prevHook, prevMask, prevCount = debug.gethook()
  debug.sethook(hook, "", HOOK_STEP)
  local ok, result = pcall(fn, ...)
  if prevHook then
    debug.sethook(prevHook, prevMask, prevCount)
  else
    debug.sethook()
  end

  if not ok then
    if timedOut then return nil, budgetText end
    return nil, tostring(result)
  end
  return true, result
end

return Dsl
