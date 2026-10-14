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

local VERSION = "0.2.0"

local CFG = {
  -- 本地桥监听的端口（要和 bridge/config.json 里的 port 一致）
  port = 8777,

  -- 项目根目录（bridge 和 Perfect Pixel 核心都在这里）。
  -- 【故意留空】——不写死任何人的绝对路径。安装时 install.ps1 会把仓库路径
  -- 写进扩展目录的 __project.lua，init() 里读出来；仓库 clone 到哪都能用。
  projectDir = nil,

  -- 打开面板时是否自动拉起本地桥（首次会弹一次"允许执行命令"授权）
  autoStartBridge = true,
}

-- require 只在 init() 作用域内可用（见 Aseprite 源码 src/app/script/require.cpp），
-- 所以所有模块必须在 init 里加载完，运行时不要再 require。
local agentModule = require("lib.agent")

local state = { agent = nil }

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

local function ensureAgent()
  if not state.agent then
    local hint = nil
    if CFG.projectDir then
      hint = string.format('node "%s\\bridge\\src\\server.mjs"', CFG.projectDir)
    end
    state.agent = agentModule.new{
      port = CFG.port,
      bridgeHint = hint,
    }
  end
  return state.agent
end

-- 后台拉起本地桥（端口已被占用时，新进程会自己安静退出）
local function startBridge()
  if not CFG.projectDir then
    return false, "找不到项目根（扩展目录里缺 __project.lua），重跑一次 install.ps1 即可"
  end
  local server = CFG.projectDir .. "\\bridge\\src\\server.mjs"
  local cmd = string.format('start "AI-Pixel-Bridge" /MIN cmd /c node "%s"', server)
  local ok, err = pcall(function() os.execute(cmd) end)
  return ok, err
end

-- 面板 + 桥：两个入口（主面板 / 小面板）共用
local function openPanel(andThen)
  local a = ensureAgent()
  if CFG.autoStartBridge then startBridge() end
  a:open()
  if andThen then pcall(andThen, a) end
  return a
end

function init(plugin)
  -- 先把项目根读出来（install.ps1 写在扩展目录的 __project.lua 里）
  CFG.projectDir = readProjectDir(plugin)

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
