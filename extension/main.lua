--[[----------------------------------------------------------------------
  AI Pixel Copilot -- Aseprite 扩展入口
  ----------------------------------------------------------------------
  控制台式 AI 对话框：
    * 用自然语言下发区域级画布操作（换色/擦除/描边/清杂点/调色板映射）
    * 输入「菜单 / menu」打开命令表：纵向排列、鼠标悬浮变蓝、点击或输入编号直接执行
    * 左上角 [.] 小按钮 -> 贴边图形小面板（图标按钮，功能与主面板一一对应）
    * 直接操作前自动备份，可 Ctrl+Z 或指令回滚，带临时版本栈
    * 上传图片 -> 调 Perfect Pixel Studio 核心算法矫正网格 -> 建成新文档
    * 记住用过的色值和场景，按需检索

  架构：Aseprite(Lua 扩展) <--WebSocket--> 本地 Node 桥 <--HTTPS--> LLM

  配置：改下面 CFG 即可。
  ----------------------------------------------------------------------]]

local VERSION = "0.3.0"

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

-- require 只在 init() 作用域内可用（见 Aseprite 源码 src/app/script/require.cpp），
-- 所以所有模块必须在 init 里加载完，运行时不要再 require。
local agentModule = require("lib.agent")

local state = { agent = nil }

-- 平台判断：package.config 的第一个字符就是路径分隔符 ——
-- "\" = Windows，"/" = macOS/Linux。（Aseprite 用的是 Lua 5.4，没有 jit.os 可用。）
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

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
--     —— 这份是自包含的（ws 都打进去了），只需系统有 node，不用 clone、不用 npm install。
--   * 从源码装：仓库里的 bridge/src/server.mjs。
-- 优先用扩展自带的那份（它更新、也更省事）。
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
  if not state.agent then
    state.agent = agentModule.new{
      port = CFG.port,
      bridgeHint = bridgeHint(),
    }
  end
  return state.agent
end

-- 后台拉起本地桥（端口已被占用时，新进程会自己安静退出）
local function startBridge()
  local entry = bridgeEntry()
  if not entry then
    return false, "找不到本地桥"
  end

  local cmd
  if IS_WINDOWS then
    -- start /MIN：另开一个最小化的窗口，不抢焦点
    cmd = string.format('start "AI-Pixel-Bridge" /MIN cmd /c node "%s"', entry)
  else
    -- nohup + &：脱离父进程在后台跑，输出留个日志方便排查
    local log = CFG.projectDir .. "/bridge/bridge.log"
    cmd = string.format('nohup node "%s" >> "%s" 2>&1 &', entry, log)
  end

  local ok, err = pcall(function() os.execute(cmd) end)
  return ok, err
end

-- 面板 + 桥：两个入口（主面板 / 小面板）共用
local function openPanel(andThen)
  local a = ensureAgent()

  if not bridgeEntry() then
    -- 扩展包里没带桥，也没记录仓库位置 —— 说明这是个不完整的安装
    -- （老的 .aseprite-extension，或者手动复制了 extension/ 而没跑 install.ps1）。
    -- 别静默失败，把该做的说清楚。
    a.panel:log("!! 找不到本地桥 —— AI 对话需要一个本地 Node 进程。", "error")
    a.panel:log("   装法 A（推荐）: 换成带桥的 .aseprite-extension 重新装一次", "info")
    a.panel:log("   装法 B（源码）: 克隆仓库后跑 install.ps1，它会记录仓库位置", "info")
    a.panel:log("        git clone https://github.com/Athosoo/aseprite-ai-pixel-copilot.git", "info")
    a.panel:log("        cd aseprite-ai-pixel-copilot && npm --prefix bridge install", "info")
    a.panel:log("        powershell -ExecutionPolicy Bypass -File install.ps1", "info")
    a.panel:log("   另外确认系统装了 Node.js 18+（node --version）", "info")
  elseif CFG.autoStartBridge then
    local ok, err = startBridge()
    if not ok then
      a.panel:log("!! 本地桥没起来: " .. tostring(err), "error")
      a.panel:log("   可以手动起: " .. bridgeHint(), "info")
    end
  end

  a:open()
  if andThen then pcall(andThen, a) end
  return a
end

function init(plugin)
  -- 项目根（clone 装法才有）+ 扩展自身目录（两种装法都有，用来找自带的桥）
  CFG.projectDir = readProjectDir(plugin)
  CFG.extPath = (plugin and plugin.path) or nil

  -- 菜单里【只留一条】：File > Scripts 下只有 "AI Pixel Copilot (AI console)"。
  -- 其余命令一律不写 group —— Aseprite 只在 group 非空时才建菜单项
  -- （plugin_class.cpp:Plugin_newCommand "Add a new menu option if the group is defined"），
  -- 但命令本身照常注册，所以 keys.aseprite-keys 里的快捷键仍然能用。
  plugin:newCommand{
    id = "ai_pixel_copilot_open",
    title = "AI Pixel Copilot (AI console)",
    group = "file_scripts",
    onclick = function() openPanel() end,
  }

  -- 下面这些【不出现在任何菜单里】，只作为命令存在：
  --   Ctrl+Shift+M -> 命令表，Ctrl+Shift+P -> 小面板（见 keys.aseprite-keys）
  --   快照 / 回滚 / 设置 -> 面板内敲「菜单」，用命令表执行
  plugin:newCommand{
    id = "ai_pixel_copilot_menu",
    title = "AI: Command Table (menu)",
    onclick = function() openPanel(function(a) a.panel:openMenu() end) end,
  }

  plugin:newCommand{
    id = "ai_pixel_copilot_palette",
    title = "AI: Small Palette (dock to edge)",
    onclick = function() openPanel(function(a) a.panel:showMini() end) end,
  }

  plugin:newCommand{
    id = "ai_pixel_copilot_snapshot",
    title = "AI: Snapshot Current Version",
    onclick = function() ensureAgent():action("snapshot") end,
  }

  plugin:newCommand{
    id = "ai_pixel_copilot_settings",
    title = "AI: Settings (API Key / Model)",
    onclick = function() openPanel(function(a) a:action("settings") end) end,
  }

  plugin:newCommand{
    id = "ai_pixel_copilot_rollback",
    title = "AI: Rollback Last Version",
    onclick = function() ensureAgent():action("rollback") end,
  }
end

function exit(plugin)
  if state.agent then
    state.agent:destroy()
    state.agent = nil
  end
end
