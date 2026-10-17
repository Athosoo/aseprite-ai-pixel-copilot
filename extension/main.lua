-- AI Pixel Copilot -- Aseprite 扩展入口（薄入口）
--
-- v1.0 起这里只做四件事：载入内核 -> 装载能力包 -> 注册 6 个命令 -> 打开工作台。
-- 业务逻辑一律在 kernel/ 与 packs/ 里：入口越薄，「新增能力要不要改内核」的答案才可能是"不用"。
--
-- 架构：Aseprite(Lua 扩展) <--WebSocket--> 本地 Node 桥 <--HTTPS--> LLM

local VERSION = "0.6.0"

local CFG = {
  -- 本地桥监听的端口（要和 bridge/config.json 里的 port 一致）
  port = 8777,

  -- 仓库根目录（clone 装法的场景）。
  -- 【故意留空】——不写死任何人的绝对路径。install.ps1 会把仓库路径写进扩展目录的
  -- __project.lua，init() 里读出来。
  projectDir = nil,

  -- 扩展自己的安装目录（plugin.path）。单文件安装（.aseprite-extension）时
  -- 桥的 bundle 就在这个目录下，靠它定位。
  extPath = nil,

  -- 打开面板时是否自动拉起本地桥（首次会弹一次"允许执行命令"授权）
  autoStartBridge = true,
}

-- 平台判断：package.config 的第一个字符就是路径分隔符 ——
-- "" = Windows，"/" = macOS/Linux。（Aseprite 用的是 Lua 5.4，没有 jit.os 可用。）
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

-- require 只在 init() 作用域内可用（STATUS.md 约束 7），所以模块全部在 init 里加载完存这里。
local M = {}
local state = {
  agent = nil,
  kernel = nil,
  kernelError = nil,
  workbench = nil,
  warnings = {},
}

-- 一行 warning：进 state.warnings（面板/扩展页可读）并打印到 Aseprite 控制台，
-- 不弹窗 —— 并行开发期间缺模块是常态，弹窗会把人烦死。
local function note(text)
  local line = tostring(text)
  state.warnings[#state.warnings + 1] = line
  print("!! AI Pixel Copilot: " .. line)
end

local function tryRequire(name)
  local ok, mod = pcall(require, name)
  if not ok then return nil, tostring(mod) end
  if type(mod) ~= "table" then return nil, name .. " did not return a table" end
  return mod
end

-- 项目根：安装时 install.ps1 写下的 __project.lua 就放在扩展目录里
-- （plugin.path 是扩展自己的安装路径，见 plugin_class.cpp:430 Plugin_get_path）。
-- 这样源码里不用写死任何人的绝对路径，仓库 clone 到哪都能用。
local function readProjectDir(plugin)
  if not (plugin and plugin.path) then return nil end
  local ok, f = pcall(io.open, plugin.path .. "/__project.lua", "r")
  if not ok or not f then return nil end
  local dir = (f:read("*a") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  f:close()
  if dir == "" then return nil end
  return dir
end

-- bridge 入口。两种装法各对应一份：
--   * 单文件安装（.aseprite-extension）：桥已经 bundle 进扩展，在 <ext>/bridge/dist/bridge.mjs
--   * 从源码装：仓库里的 bridge/src/server.mjs
local function bridgeEntry()
  if CFG.extPath then
    local bundled = CFG.extPath .. "/bridge/dist/bridge.mjs"
    local f = io.open(bundled, "r")
    if f then
      f:close()
      return bundled
    end
  end
  if CFG.projectDir then
    return CFG.projectDir .. "/bridge/src/server.mjs"
  end
  return nil
end

-- 给用户看的"手动起桥"命令（连不上时打在面板里）
local function bridgeHint()
  local entry = bridgeEntry()
  if not entry then return "node bridge/src/server.mjs    # 在仓库根跑" end
  return string.format('node "%s"', entry)
end

local function ensureAgent()
  if not M.agent then return nil, "lib.agent 未加载" end
  if not state.agent then
    state.agent = M.agent.new{
      port = CFG.port,
      bridgeHint = bridgeHint(),
      -- 引擎句柄：能力包的算子名单与执行都要它。不给的话 agent 会安全降级成
      -- "只看得到内建 10 个算子、包算子一执行就 unknown op" —— 等于自扩展白做。
      kernel = state.kernel,
    }
  end
  return state.agent
end

-- ---- 找 node ------------------------------------------------------------
-- 为什么不能只写裸 node：Aseprite 从图形界面启动时，PATH 未必带 Node（很多机器
-- 装了 Node 但只在用户 PATH 或默认安装目录里）。找不到就说清楚试过哪些地方。
local sep = IS_WINDOWS and "\\" or "/"

function resolveNode(deps)
  deps = deps or {}
  local exists = deps.exists or function(p)
    local f = io.open(p, "rb")
    if f then f:close(); return true end
    return false
  end
  local env = deps.env or function(k) return os.getenv(k) end
  local tried = {}

  local names = IS_WINDOWS and { "node.exe", "node.cmd", "node.bat" } or { "node" }

  -- 1) PATH 里的 node（自己拆 PATH：io.open("node.exe") 找不到 PATH 上的东西）
  local pathVar = env("PATH") or ""
  local sepChar = IS_WINDOWS and ";" or ":"
  for dir in string.gmatch(pathVar, "[^" .. sepChar .. "]+") do
    for _, name in ipairs(names) do
      local cand = dir:gsub("[\\/]+$", "") .. sep .. name
      tried[#tried + 1] = cand
      if exists(cand) then return cand, nil, tried end
    end
  end

  -- 2) 官方安装的默认目录
  local pf = env("ProgramFiles")
  if pf and pf ~= "" then
    local cand = pf .. sep .. "nodejs" .. sep .. "node.exe"
    tried[#tried + 1] = cand
    if exists(cand) then return cand, nil, tried end
  end

  -- 3) 用户级安装（官方 zip / nvs / winget 都落在这里）
  local lad = env("LOCALAPPDATA")
  if lad and lad ~= "" then
    local cand = lad .. sep .. "Programs" .. sep .. "nodejs" .. sep .. "node.exe"
    tried[#tried + 1] = cand
    if exists(cand) then return cand, nil, tried end
  end

  return nil, "找不到 node（试过 PATH、ProgramFiles\\nodejs、LOCALAPPDATA\\Programs\\nodejs）", tried
end

-- ---- 端口探测 -----------------------------------------------------------
-- 桥已经在跑时再起一个只会撞端口、多一个立刻退出的 node 进程。
-- netstat 的输出里只有 LISTENING 行才算"有桥在听"（TIME_WAIT 之类不算）。
function portInUse(port, deps)
  port = tonumber(port) or 8777
  deps = deps or {}
  local tmp = deps.tmpPath or ((os.getenv("TEMP") or ".") .. "/ai-pixel-copilot-port-" .. port .. ".tmp")
  local cmd = string.format('netstat -ano | findstr ":%d" > "%s" 2>nul', port, tmp)
  local ok = pcall(function()
    if deps.run then return deps.run(cmd) end
    return os.execute(cmd)
  end)
  if not ok then return false, "netstat 执行失败" end

  local text = ""
  if deps.output ~= nil then
    text = tostring(deps.output)
  else
    local f = io.open(tmp, "rb")
    if f then text = f:read("*a") or ""; f:close() end
    pcall(function() os.remove(tmp) end)
  end

  for line in text:gmatch("[^\r\n]+") do
    if line:find("LISTENING", 1, true) ~= nil and line:find(":" .. port, 1, true) ~= nil then
      return true, "端口 " .. port .. " 已有进程在监听"
    end
  end
  return false
end

-- 后台拉起本地桥。返回 state, detail：
--   "already" 桥已在监听（不重复起） / "started" 已拉起 / "failed" 起不来（detail 说原因）
function startBridge(deps)
  deps = deps or {}
  -- 先看端口：已经在跑就根本不需要桥入口，更不该再起一个
  local busy = deps.portBusy
  if busy == nil then busy = portInUse(CFG.port, deps) end
  if busy then
    return "already", "端口 " .. tostring(CFG.port) .. " 已有桥在监听，跳过启动"
  end

  local entry = deps.entry or bridgeEntry()
  if not entry then
    return "failed", "找不到本地桥入口（扩展里没有 bridge/dist/bridge.mjs，也没有 __project.lua）"
  end

  local nodePath, nodeErr = resolveNode(deps)
  if not nodePath then
    return "failed", tostring(nodeErr) .. "；装好 Node.js 18+ 后重开面板，或手动起桥: " ..
      string.format('"%s" "%s"', "node", entry)
  end

  local cmd
  if IS_WINDOWS then
    -- start /MIN：另开一个最小化的窗口，不抢焦点；标题占位是 start 的语法要求
    cmd = string.format('start "AI-Pixel-Bridge" /MIN "%s" "%s"', nodePath, entry)
  else
    local log = (CFG.projectDir or ".") .. "/bridge/bridge.log"
    cmd = string.format('nohup "%s" "%s" >> "%s" 2>&1 &', nodePath, entry, log)
  end

  local ok, rc = pcall(function()
    if deps.run then return deps.run(cmd) end
    return os.execute(cmd)
  end)
  if not ok then
    return "failed", "拉起桥的命令执行失败: " .. tostring(rc)
  end
  return "started", "已拉起桥（node = " .. nodePath .. "）"
end

-- 工作台（T2 的 lib.workbench）：它没落地时回落到旧面板，三路并行谁也别等谁。
-- 接口按 arch §2 的依赖方向：工作台只认 registry / bus / host，不认具体视图。

-- agent 调 panel 的 25 个方法、工作台只有 6 个：界面换成工作台却不换 agent 的数据通道，
-- 就是「界面活、数据全进旧面板」—— 面板点不动的真根因。适配层由 T2 提供
-- （lib/panel_adapter），这里只负责把它装到 agent 上；装不上就原样保留旧 panel。
-- 导出成全局 + 第三个参数可注入模块，是为了让无头测试能直接验"换得成/换不成"两条分支
-- （脚本里的 local 测试够不到；生产调用只传前两个参数）。
function swapAgentPanel(a, wb, adapterModule)
  if not (a and a.panel) then return false end
  local mod = adapterModule
  if mod == nil then mod = M.panelAdapter or tryRequire("lib.panel_adapter") end
  if not mod then
    note("lib/panel_adapter 不可用：工作台已显示，但 agent 仍绑旧面板（界面会点不动）")
    return false
  end

  local function attempt(fn, ...)
    local ok, res = pcall(fn, ...)
    if not ok then return nil, res end
    if type(res) ~= "table" then return nil, "构造没有返回对象（got " .. type(res) .. "）" end
    return res, nil
  end

  -- lib/panel_adapter 的正式入口是 attach(agent, wb)（它自己就把 agent.panel 换掉）；
  -- 次选是 new(wb, { fallback = 旧panel, agent = agent })。两种都不认就保留旧 panel。
  local built, buildErr
  if type(mod) == "table" and type(mod.attach) == "function" then
    built, buildErr = attempt(mod.attach, a, wb)
  elseif type(mod) == "table" and type(mod.new) == "function" then
    built, buildErr = attempt(mod.new, wb, { fallback = a.panel, agent = a, kernel = state.kernel })
  else
    buildErr = "lib/panel_adapter 既没有 attach 也没有 new"
  end

  if not built then
    note("面板适配层构造失败，agent 仍绑旧面板: " .. tostring(buildErr))
    return false
  end
  a.panel = built
  state.panelAdapter = built
  return true
end

function openWorkbench(a, wbModule)
  local mod = wbModule or M.workbench
  if not mod or not mod.new then return false end
  local wb = nil
  -- pcall 的第二个返回值才是真正的错误：只接 ok 会让日志永远说"returned nil"，
  -- 真机排查时那条日志等于没用。抛错和返回 nil 分开记，一眼能分辨。
  local ok, err = pcall(function()
    wb = mod.new{
      kernel = state.kernel,
      agent = a,
      registry = state.kernel and state.kernel.registry or nil,
      bus = state.kernel and state.kernel.bus or nil,
      host = state.kernel and state.kernel.host or nil,
    }
  end)
  if not ok then
    note("工作台构造失败，已回落到旧面板: " .. tostring(err))
    return false
  end
  if not wb then
    note("lib.workbench.new 返回了 nil，已回落到旧面板")
    return false
  end
  state.workbench = wb
  if type(wb.show) == "function" then
    local shown, serr = pcall(function() wb:show() end)
    if not shown then
      note("工作台 show() 失败，已回落到旧面板: " .. tostring(serr))
      return false
    end
  elseif type(wb.open) == "function" then
    local shown, serr = pcall(function() wb:open() end)
    if not shown then
      note("工作台 open() 失败，已回落到旧面板: " .. tostring(serr))
      return false
    end
  end

  -- 界面换成工作台之后，agent 的数据通道仍指着旧 panel：不换就是「界面活、数据全进死面板」。
  -- 但 agent 调 panel 的 25 个方法、工作台只有 6 个，所以中间必须有适配层（T2 的
  -- lib/panel_adapter）。拿不到适配层就保持旧 panel —— 行为与之前一字不变。
  swapAgentPanel(a, wb)
  return true
end

-- ---- UI 模式：默认工作台，旧面板是显式可选 -------------------------------
-- 默认是工作台：这一个 UI 就是主界面，要继续把它做完善。
-- 唯一切成旧面板的方式：在扩展目录写一个 ui.mode 文件，内容一个字 legacy。
-- 其它一切（不存在/空/写错/读失败）都留在工作台 —— 只有明确要求才退，不猜。
local UI_MODE_DEFAULT = "workbench"

function uiModeFrom(text)
  if type(text) ~= "string" then return UI_MODE_DEFAULT end
  -- 约束 32/33b：BOM 和回车符会破坏 ^%s* 匹配（%s 在这个 Lua 里不吃回车），先手工洗掉
  local v = text:gsub("^\239\187\191", "")
  v = v:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", "")
  v = v:lower()
  if v == "legacy" then return "legacy" end
  return UI_MODE_DEFAULT
end

function readUiMode(baseDir)
  local dir = (type(baseDir) == "string" and baseDir ~= "") and baseDir or nil
  if not dir then return UI_MODE_DEFAULT end
  local ok, mode = pcall(function()
    local f = io.open(dir .. "/ui.mode", "rb")
    if not f then return UI_MODE_DEFAULT end   -- 文件不存在
    local text = f:read("*a")
    f:close()
    return uiModeFrom(text)
  end)
  if not ok then return UI_MODE_DEFAULT end    -- 读失败（权限/被占用/是目录…）静默用默认
  return mode or UI_MODE_DEFAULT
end

-- 呈现路径：legacy 绝不构造工作台；workbench 起不来才回落旧面板。
-- 返回 "workbench" | "legacy" | "legacy-fallback"，便于测试与日志核对。
function presentUi(a, mode, forceWorkbench, wbModule)
  if not (a and type(a.open) == "function") then return "legacy" end
  local wantWorkbench = forceWorkbench == true or mode ~= "legacy"
  if wantWorkbench then
    if openWorkbench(a, wbModule) then return "workbench" end
    a:open()
    return "legacy-fallback"
  end
  a:open()
  return "legacy"
end

-- 工作台只画状态、不负责连；旧面板在 a:open() 里已经连过了。
-- 少了这一步，默认走工作台时根本没人发起连接 —— 正是"无法连接桥"的一半原因。
function connectIfNeeded(a, uiPath)
  if uiPath == "legacy" then return false end
  if not (a and type(a.connect) == "function") then return false end
  pcall(function() a:connect(true) end)
  return true
end

-- 面板 + 桥：两个入口（主面板 / 小面板）共用
local function openPanel(andThen, forceWorkbench)
  local a, aerr = ensureAgent()
  if not a then
    note("面板不可用: " .. tostring(aerr))
    return nil
  end

  if not bridgeEntry() then
    -- 扩展包里没带桥，也没记录仓库位置 —— 说明这是个不完整的安装。
    -- 别静默失败，把该做的说清楚。
    a.panel:log("!! 找不到本地桥 —— AI 对话需要一个本地 Node 进程。", "error")
    a.panel:log("   装法 A（推荐）: 换成带桥的 .aseprite-extension 重新装一次", "info")
    a.panel:log("   装法 B（源码）: 克隆仓库后跑 install.ps1，它会记录仓库位置", "info")
    a.panel:log("        powershell -ExecutionPolicy Bypass -File install.ps1", "info")
    a.panel:log("   另外确认系统装了 Node.js 18+（node --version）", "info")
  elseif CFG.autoStartBridge then
    local state, detail = startBridge()
    if state == "failed" then
      a.panel:log("!! 本地桥没起来: " .. tostring(detail), "error")
      a.panel:log("   手动起: " .. bridgeHint(), "info")
    elseif state == "already" then
      a.panel:log(tostring(detail) .. "，直接连接", "info")
    else
      a.panel:log(tostring(detail), "info")
    end
  end

  local uiPath = presentUi(a, readUiMode(CFG.extPath), forceWorkbench == true)
  connectIfNeeded(a, uiPath)
  if andThen then pcall(andThen, a) end
  return a
end

-- 命令表：id 与 v0.5.9 逐字一致（D4 硬要求），菜单只挂 open 一条。
-- group 非空 Aseprite 才建菜单项（plugin_class.cpp:Plugin_newCommand），
-- 其余命令只作为命令存在 —— keys.aseprite-keys 里的快捷键照旧能用。
local COMMANDS = {
  {
    id = "ai_pixel_copilot_open",
    title = "AI Pixel Copilot (AI console)",
    group = "file_scripts",
    keys = "Ctrl+Shift+A",
    onclick = function() openPanel() end,
  },
  {
    id = "ai_pixel_copilot_menu",
    title = "AI: Command Table (menu)",
    keys = "Ctrl+Shift+M",
    onclick = function() openPanel(function(a) a.panel:openMenu() end) end,
  },
  {
    id = "ai_pixel_copilot_palette",
    title = "AI: Small Palette (dock to edge)",
    keys = "Ctrl+Shift+P",
    onclick = function() openPanel(function(a) a.panel:showMini() end) end,
  },
  {
    id = "ai_pixel_copilot_snapshot",
    title = "AI: Snapshot Current Version",
    onclick = function() ensureAgent():action("snapshot") end,
  },
  {
    id = "ai_pixel_copilot_settings",
    title = "AI: Settings (API Key / Model)",
    onclick = function() openPanel(function(a) a:action("settings") end) end,
  },
  {
    id = "ai_pixel_copilot_rollback",
    title = "AI: Rollback Last Version",
    onclick = function() ensureAgent():action("rollback") end,
  },
  -- 工作台就是默认界面；这条命令是「强制打开工作台」——用户写了 ui.mode=legacy
  -- 想临时切回来时用它。不挂 group，所以 File > Scripts 下仍然只有 open 一条（D4）。
  {
    id = "ai_pixel_copilot_workbench",
    title = "AI: Open Workbench (beta)",
    hint = "实验性三区工作台；出问题请回到默认面板",
    onclick = function() openPanel(nil, true) end,
  },
}

-- 账本发 pack.disabled / pack.rolledback，入口订阅后转成"撤算子"：
-- 这样 ledger 不认识 agent、agent 不认识 ledger，两条线在入口交汇。
-- 导出成全局是为了让无头测试能直接验这条线（local 的拿不到）。
-- onPackGone 缺省就走 agent.dropPackOps（模块级函数，不需要 agent 实例）。
function wirePackEvents(getKernel, onPackGone)
  local kernel = getKernel and getKernel() or nil
  if not kernel or not kernel.bus then return nil end

  local function handle(payload)
    local id = payload and payload.id or nil
    if id == nil then return end
    local gone = onPackGone
    if not gone then
      gone = function(packId)
        if not M.agent or not M.agent.dropPackOps then return 0 end
        return M.agent.dropPackOps(state.kernel, packId)
      end
    end
    local ok, removed = pcall(gone, tostring(id))
    if not ok then
      -- 撤算子失败不该让启停失败；但要留痕，否则就是"名单里悄悄留了 ghost"
      note("撤算子失败(" .. tostring(id) .. "): " .. tostring(removed))
    elseif removed and removed > 0 then
      state.kernel.ledger:journal({ event = "pack.ops_dropped", id = tostring(id), removed = removed })
    end
  end

  return { kernel.bus:on("pack.disabled", handle), kernel.bus:on("pack.rolledback", handle) }
end

local function runCommand(cmd)
  local ok, err = pcall(cmd.onclick)
  if not ok then
    note(string.format("命令 %s 失败: %s", cmd.id, tostring(err)))
  end
end

-- 内建视图 id（与 packs/builtin/core/manifest.json 的 views 一一对应）
local VIEW_IDS = { "console", "canvas", "packs", "styles", "memory", "gallery", "settings" }

-- 视图实现（lib/views/*）也必须在 init() 里 require 完：工作台是运行时才挂载视图的，
-- 那时 require 已经不在了（约束 7）。所以这里把 mount 函数表交给内核，由 core 包的
-- view 规格在 mount 时转交 —— 布局归 T2，接线归入口。
-- 各视图导出的形状不统一（mount / new），这里统一包成 mount(ctx) -> view。
local function buildRenderers()
  local renderers = {}
  for _, id in ipairs(VIEW_IDS) do
    local mod = tryRequire("lib.views." .. id)
    if type(mod) == "table" then
      if type(mod.mount) == "function" then
        renderers[id] = function(ctx) return mod.mount(ctx) end
      elseif type(mod.new) == "function" then
        renderers[id] = function(ctx) return mod.new(ctx) end
      end
    end
  end
  return renderers
end

-- 能力包目录：builtin 先、user 后（同 id 后者覆盖前者，见 ledger:scan）
local function packsDirs()
  local dirs = {}
  if CFG.extPath then dirs[#dirs + 1] = CFG.extPath .. "/packs/builtin" end
  local okUser, userErr = pcall(function()
    local user = app.fs.joinPath(app.fs.joinPath(app.fs.userConfigPath, "ai-pixel-copilot"), "packs")
    dirs[#dirs + 1] = user
  end)
  if not okUser then note("拿不到用户能力包目录（自建包将不可见）: " .. tostring(userErr)) end
  return dirs
end

-- 内核加载失败只记录可读错误（不崩、不弹窗）：扩展仍然可用旧面板。
local function loadKernel()
  local mod, err = tryRequire("kernel.init")
  if not mod then
    state.kernelError = "内核加载失败: " .. tostring(err)
    note(state.kernelError)
    return nil
  end

  local kernel, kerr = nil, nil
  -- 同一个毛病：抛错时 kernel 是 nil，只接 ok 会把"内核组装失败: nil"写进日志
  local ok, kErr = pcall(function()
    kernel, kerr = mod.new{
      app = app,
      versions = M.versions,
      -- 包跑在沙箱里，算子的实现只能由这里显式交进去（packs/builtin/ops）
      shared = { ops = M.ops },
      ledger = { packsDirs = packsDirs() },
    }
  end)
  if not ok then
    state.kernelError = "内核组装抛错: " .. tostring(kErr)
    note(state.kernelError)
    return nil
  end
  if not kernel then
    state.kernelError = "内核组装失败: " .. tostring(kerr)
    note(state.kernelError)
    return nil
  end

  local mounted, merr = pcall(mod.mountPacks, kernel, { renderers = M.renderers })
  if not mounted then note("能力包装载失败: " .. tostring(merr)) end
  for _, e in ipairs(kernel.packErrors or {}) do
    note(string.format("能力包 %s 有问题: %s", tostring(e.id), tostring(e.err)))
  end

  state.kernel = kernel
  M.kernelInit = mod
  return kernel
end

function init(plugin)
  -- 项目根（clone 装法才有）+ 扩展自身目录（两种装法都有，用来找自带的桥）
  CFG.projectDir = readProjectDir(plugin)
  CFG.extPath = (plugin and plugin.path) or nil

  -- UI 模式：默认工作台。想用旧面板就在扩展目录写 ui.mode，内容一行 legacy；
  -- 删掉/写错/读不到都留在工作台。见 readUiMode()。
  --
  -- 所有 require 在这里一次性做完（约束 7），任何一个失败都只降级、不抛
  M.agent = (tryRequire("lib.agent"))
  M.versions = (tryRequire("lib.versions"))
  M.ops = (tryRequire("lib.ops"))
  M.workbench = (tryRequire("lib.workbench"))
  -- 适配层可能还没落地（T2 在写）：晚于本行出现也没关系，swapAgentPanel 里还有一次运行时补试
  M.panelAdapter = (tryRequire("lib.panel_adapter"))
  -- 工作台若自带视图渲染器表就用它的，否则用 lib/views/*（内核不决定布局，只负责接线）
  M.renderers = (M.workbench and M.workbench.renderers) or buildRenderers()
  if not M.workbench then
    note("lib.workbench 未落地，工作台暂时回落到旧面板")
  end

  loadKernel()

  -- 内核可能比 agent 晚就绪（agent 是懒构造的，也可能先于 loadKernel 被建出来）：两边都补一次
  if state.kernel and state.agent and type(state.agent.setKernel) == "function" then
    pcall(function() state.agent:setKernel(state.kernel) end)
  end
  if state.kernel then
    local ok, subErr = pcall(wirePackEvents, function() return state.kernel end)
    if not ok then note("pack 事件接线失败: " .. tostring(subErr)) end
  end

  for _, cmd in ipairs(COMMANDS) do
    plugin:newCommand{
      id = cmd.id,
      title = cmd.title,
      group = cmd.group,
      onclick = function() runCommand(cmd) end,
    }
    if state.kernel then
      state.kernel.registry:define("command", {
        id = cmd.id,
        title = cmd.title,
        keys = cmd.keys,
        hint = cmd.group and "菜单 File > Scripts" or "命令 + 快捷键",
        run = function(ctx, arg) runCommand(cmd) return true end,
      })
    end
  end
end

function exit(plugin)
  state.workbench = nil
  state.panelAdapter = nil
  if state.agent then
    pcall(function() state.agent:destroy() end)
    state.agent = nil
  end
end
