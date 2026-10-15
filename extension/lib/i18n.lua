-- lib/i18n.lua -- 界面语言（中/英，默认中文）+ 终端内建命令的触发词
--
-- 三件事：
--   1) 定语言：Aseprite 首选项 [general] language（zh_hans / en）优先；
--      没设（默认 "en"）时看系统语言（中文系统 -> zh_hans）；否则默认【中文】。
--   2) 界面文案 + 面板按钮 + 帮助文本的双语表。
--   3) 终端内建命令：菜单 / 清屏 / 帮助 / 设置 / 快照 / 回滚 / 版本 / 退出
--      （英文同义词 menu / cls / help / settings / ... 都认）。
--
-- 注意这个 Lua 是 POSIX 正则版：**模式里的 "|" 不生效**，一律查表匹配。
-- 另外 string.lower() 是字节级的，含非 ASCII 时不能调。

local i18n = {}

-- 面板/小面板上的按钮标题、小面板格子标签、内建命令词表
local LOCALES = {
  en = {
    inputHint  = "type here -- Enter runs it, menu lists commands",
    fixTitle   = "Fix images (Perfect Pixel)",
    fixIntro   = "Files to fix:",
    fixAdd     = "Add file",
    fixRun     = "Start",
    fixCancel  = "Cancel",
    fixCount   = "%d file(s) queued -- Start fixes them all",
    fixMore    = "  ... (+%d more)",
    fixEmpty   = "(nothing queued yet)",
    prompt     = "Type a command -- menu lists everything",
    hint       = "PowerShell-style console: type a command and press Enter. menu = command table, cls = clear, help = examples.",
    statusBar  = "%s",
    menuTitle  = "COMMANDS",
    menuFooter = "hover to highlight  -  click or type the number to run  -  x = close",
    menuOpen   = "Command table opened. Type a number, or hover a row and click it.",
    menuClosed = "Command table closed.",
    noCommands = "(menu is empty -- no commands registered)",
    queued     = "Not connected yet -- queued, will send as soon as the bridge is up.",
    pickFile   = "Pick an image file first (the box under the buttons, or Upload in the small palette).",
    nothingToDo= "This command does nothing right now.",
    clearDone  = "Console cleared.",
    bye        = "Console closed (the panel stays open).",
    helpTitle  = "Examples:",
    helpBody   = "  replace #FF0000 with #2E86DE\n  erase all #00FF00\n  outline the subject with #1B1B1B\n  remove stray pixels\n  remember #2E86DE is my blue shell color, tags: shell, blue\n  which shell colors did I use before?\n  roll back to the previous version",
    helpBuiltin= "Built-in commands:  menu / cls / help / settings / snapshot / rollback / versions / fix / exit",
    starting   = "starting...",
    readyStatus= "ready",
    connected  = "connected",
    statusWorking = "working (step %d)...",
    statusRunning = "running %s...",
    statusMap = {
      ["thinking..."] = "thinking...",
      ["ready"] = "ready",
      ["connected, waiting for input"] = "connected, waiting for input",
      ["missing API key"] = "missing API key",
      ["testing LLM..."] = "testing LLM...",
      ["error"] = "error",
      ["connecting"] = "connecting",
      ["disconnected"] = "disconnected",
    },
    disconnected = "disconnected",
    connecting = "connecting to %s ...",
    connError  = "connection error",
    connErrorDetail = "Connection error: %s",
    connectingLong = "Connecting to the local bridge. If it never connects, start it manually:",
    bridgeDown = "Bridge is down -- type menu > Settings to check the config, or start the bridge manually.",
    tooSmall   = "Window too small -- drag it bigger",
    askTitle   = "Choose an option",
    askOption  = "  %d) %s",
    askHint    = "(type the number, or click a button in the dialog)",
    askAnswered= "Answered: %s",
    askCancelled = "Question dismissed.",
    askSuperseded = "Previous question was replaced by a new one.",
    -- P10 工作区
    wsNoDoc    = "No document is open.",
    wsNoPath   = "No path given, and there is no workspace or saved document to resolve it against.",
    wsNeedSave = "This document has never been saved. Save it first (File > Save As) so there is an original to back up and deliver to.",
    wsMakeDir  = "create the folder",
    wsBackup   = "write the backup",
    wsBackupVerify = "verify the backup file",
    wsCopy     = "write the copy",
    wsCopyIn   = "copy the file into the workspace",
    wsOpen     = "open the copy",
    wsStepFailed = "Workspace step failed (%s): %s -- the edit was aborted, nothing was changed.",
    wsOpenWrong  = "Aseprite opened %s instead of the copy; aborting so the edit does not land on the wrong document.",
    wsPrepared = "Backed up to %s -- now editing the copy %s. Type deliver when you are done.",
    wsOverwrite = "Overwrite the original",
    wsKeep     = "Keep the copy",
    wsDiscard  = "Throw the copy away",
    wsContinue = "Keep editing",
    wsNothingPending = "Nothing to deliver: no copy is being edited.",
    wsNotTheCopy = "The active document is not the working copy, so there is nothing to overwrite with.",
    wsOverwritten = "Overwrote %s (backup kept at %s).",
    wsKept      = "Kept the copy %s (backup at %s).",
    wsDiscarded = "Deleted the copy %s (backup kept at %s).",
    wsUnknownChoice = "Unknown delivery choice: %s",
    wsTitle     = "Deliver the edit",
    wsQuestion  = "This copy was edited. What should happen to it?",
    wsCopiedIn  = "Copied into the workspace: %s",
    wsNothing   = "(the workspace has no files yet)",
    -- P11 打开文档
    wsOpenDocFailed = "Cannot open %s: %s",
    wsOpenDocBadExt = "Refusing to open %s: only image/document files can be opened (ase/aseprite/png/jpg/gif/webp/bmp).",
    wsOpened    = "Opened %s (%dx%d).",
    wsCopyTag   = "[copy]",
    modePanel   = "panel",
    modeBarBottom = "bottom bar",
    modeBarSide = "side bar",
    modeChanged = "Layout: %s",
    barHint     = "Drag this strip to the bottom or side edge -- Aseprite gives scripts no dock API, so it stays a floating strip.",
    wsDisabled  = "Workspace mode is off (set workspace.root in the settings to turn it on).",
    wsListTitle = "Workspace files (%d):",
    wsListNone  = "(no files in uploads/ or backups/ yet)",
    openDocHint = "To open a file, just tell the assistant which one (e.g. \"open 001.ase\") -- it resolves paths inside the workspace.",
    aborted    = "Task interrupted.",
    abortTimeout = "Task timed out and was interrupted automatically.",
    abortSent  = "Interrupt requested...",
    abortNothing = "Nothing is running right now.",
    bridged    = "Connected to local bridge %s",
    testing    = "Testing LLM connection...",
    backedUp   = "Backed up: v%d \"%s\"  %s",
    autoBacked = "Auto-backed up v%d \"%s\"",
    snapFailed = "Backup failed: %s",
    rolledBack = "Rolled back to v%d \"%s\"  (%d/%d cels)",
    rollbackFailed = "Rollback failed: %s",
    layersGone = "Layers no longer present, not restored: %s",
    noSnapshots= "No snapshots yet.",
    versionStack = "Version stack (%d):",
    applied    = "Applied %d op(s) on layer %s -- %s",
    openedDoc  = "Opened a new %dx%d document -- copy it into your own canvas.%s",
    unknownAction = "Unknown action: %s",
    fileDialogFailed = "File dialog failed to open (%s); use the file box under the buttons instead.",
    loadedFixing = "Loaded %s -- now fixing it (Perfect Pixel)...",
    reading    = "Reading image: %s",
    loadedSending = "Loaded %dx%d, sending to the bridge for grid detection...",
    readFailed = "Read failed: %s",
    unknownMessage = "Unknown message: %s",
    unexpectedFrame = "Unexpected binary frame: %s",
    opsFailed  = "Ops failed, canvas untouched: %s",
    sizeDone   = "%s: %s -> %s",
    sizeNoop   = "%s: nothing to do (%s)",
    sizeFailed = "Resize failed, canvas untouched: %s",
    artDrawn   = "Drew %d px (%dx%d) on layer %s",
    artClipped = "  (%d px fell outside the canvas and were skipped)",
    artDoc     = "%s: %s",
    artFailed  = "Drawing failed, canvas untouched: %s",
    blurry     = "If the result looks blurry, the source probably was not pixel art, or the grid was misdetected: retry with an explicit grid size.",
    importFailed = "Import failed: %s",
    importMismatch = "Import size mismatch: got %d bytes, expected %d",
    ready      = "AI Pixel Copilot ready. Backups are automatic; undo with Ctrl+Z or rollback.",
    tipMenu    = "Type menu (or 菜单) for the command table.  ↑/↓ recalls history.",
    think      = "thinking",
    buttons = {
      send = "Send", menu = "[M]", panel = "[.]",
      snapshot = "Snapshot", rollback = "Rollback", versions = "Versions",
      reconnect = "Reconnect", settings = "Settings", fix = "Fix Image",
    },
    mini = {
      snapshot = "Snapshot", rollback = "Rollback", versions = "Versions",
      fix = "Fix images", bar = "Layout", settings = "Settings", close = "Hide",
    },
    -- 内建命令 -> 动作 id
    builtins = {
      menu = "menu", help = "help", ["?"] = "help", cls = "clear", clear = "clear",
      settings = "settings", config = "settings", snapshot = "snapshot", backup = "snapshot",
      rollback = "rollback", undo = "rollback", versions = "versions", history = "versions",
      fix = "fix", upload = "upload", open = "upload", reconnect = "reconnect",
      stop = "abort", abort = "abort", interrupt = "abort", cancel = "abort",
      deliver = "deliver", opendoc = "open_doc", ["open-doc"] = "open_doc",
      exit = "@exit", quit = "@exit", close = "@exit", bye = "@exit",
    },
  },

  zh_hans = {
    inputHint  = "在这里输入 —— 回车执行，敲 menu 看命令表",
    fixTitle   = "图片矫正（Perfect Pixel）",
    fixIntro   = "要矫正的图片：",
    fixAdd     = "添加文件",
    fixRun     = "开始矫正",
    fixCancel  = "取消",
    fixCount   = "已排 %d 张 —— 点开始就会逐张矫正",
    fixMore    = "   …（还有 %d 张）",
    fixEmpty   = "（还没有添加文件）",
    prompt     = "输入指令，回车执行（输入 menu 或 菜单 看命令表）",
    hint       = "PowerShell 式控制台：直接敲指令回车。menu 命令表 / cls 清屏 / help 示例。",
    statusBar  = "%s",
    menuTitle  = "命令表",
    menuFooter = "悬浮高亮  -  点击或输入编号执行  -  x 关闭",
    menuOpen   = "命令表已打开：输入编号，或鼠标悬浮某行点击执行。",
    menuClosed = "命令表已关闭。",
    noCommands = "（菜单是空的：没有注册任何命令）",
    queued     = "还没连上桥 -- 已排队，桥一起来就发送。",
    pickFile   = "先选一张图片（按钮下方的文件框，或小面板里的「选图」）。",
    nothingToDo= "这条命令目前无事可做。",
    clearDone  = "已清屏。",
    bye        = "控制台已关闭（面板还开着）。",
    helpTitle  = "示例指令：",
    helpBody   = "  把背景的 #FF0000 换成 #2E86DE\n  删掉所有 #00FF00\n  给主体加一圈 #1B1B1B 描边\n  清理孤立杂点\n  记住 #2E86DE 是我蓝色外壳的主体色，标签：外壳、蓝\n  我之前用过哪些外壳色？\n  回滚到上一个版本",
    helpBuiltin= "内建命令： 菜单/menu  清屏/cls  帮助/help  设置/settings  快照/snapshot  回滚/rollback  版本/versions  退出/exit",
    starting   = "启动中...",
    readyStatus= "就绪",
    connected  = "已连接",
    statusWorking = "正在处理（第 %d 步）…",
    statusRunning = "正在执行 %s…",
    statusMap = {
      ["thinking..."] = "思考中…",
      ["ready"] = "就绪",
      ["connected, waiting for input"] = "已连接，等待输入",
      ["missing API key"] = "缺少 API Key",
      ["testing LLM..."] = "正在测试 LLM...",
      ["error"] = "出错",
      ["connecting"] = "连接中",
      ["disconnected"] = "已断开",
    },
    disconnected = "已断开",
    connecting = "正在连接 %s ...",
    connError  = "连接出错",
    connErrorDetail = "连接出错：%s",
    connectingLong = "正在连接本地桥；如果一直连不上，手动启动它：",
    bridgeDown = "桥断了 —— 敲 menu → 设置 检查配置，或手动启动桥（见上方提示）。",
    tooSmall   = "窗口太小，请拖大一点",
    askTitle   = "请选择",
    askOption  = "  %d）%s",
    askHint    = "（输入编号，或点弹窗里的按钮）",
    askAnswered= "已选择：%s",
    askCancelled = "已取消这次提问。",
    askSuperseded = "上一个问题被新问题顶掉了。",
    -- P10 工作区
    wsNoDoc    = "当前没有打开的文档。",
    wsNoPath   = "没给路径，也没有工作区或已保存的文档可以拿来定位。",
    wsNeedSave = "这个文档从没保存过。请先另存为一个文件（文件 → 另存为），这样才有原文件可以备份和交付。",
    wsMakeDir  = "建目录",
    wsBackup   = "写备份",
    wsBackupVerify = "校验备份文件",
    wsCopy     = "写副本",
    wsCopyIn   = "把文件复制进工作区",
    wsOpen     = "打开副本",
    wsStepFailed = "工作区步骤失败（%s）：%s —— 本次编辑已中止，画布没有被改动。",
    wsOpenWrong  = "Aseprite 打开的是 %s，不是副本；为防止改错文档，已中止本次编辑。",
    wsPrepared = "已备份到 %s，正在编辑副本 %s。改完敲「交付」。",
    wsOverwrite = "覆盖原文件",
    wsKeep     = "保留副本",
    wsDiscard  = "丢弃副本",
    wsContinue = "继续修改",
    wsNothingPending = "没有待交付的内容：当前没有在编辑副本。",
    wsNotTheCopy = "当前文档不是那份副本，没法用它覆盖原文件。",
    wsOverwritten = "已覆盖 %s（备份留在 %s）。",
    wsKept      = "已保留副本 %s（备份在 %s）。",
    wsDiscarded = "已删除副本 %s（备份留在 %s）。",
    wsUnknownChoice = "未知的交付选项：%s",
    wsTitle     = "交付这次修改",
    wsQuestion  = "这份副本已经改过了，要怎么处理？",
    wsCopiedIn  = "已复制进工作区：%s",
    wsNothing   = "（工作区里还没有文件）",
    -- P11 打开文档
    wsOpenDocFailed = "打不开 %s：%s",
    wsOpenDocBadExt = "拒绝打开 %s：只能打开图片/文档类文件（ase/aseprite/png/jpg/gif/webp/bmp）。",
    wsOpened    = "已打开 %s（%dx%d）。",
    wsCopyTag   = "［副本］",
    modePanel   = "面板",
    modeBarBottom = "底边栏",
    modeBarSide = "侧边栏",
    modeChanged = "已切换形态：%s",
    barHint     = "把这条拖到底边或侧边即可 —— Aseprite 没给脚本停靠接口，所以它是一条浮动条。",
    wsDisabled  = "工作区模式没开（在设置里填「工作区路径」可以打开）。",
    wsListTitle = "工作区文件（%d）：",
    wsListNone  = "（uploads/ 和 backups/ 里还没有文件）",
    openDocHint = "要打开文件，直接跟助手说文件名（例如「打开 001.ase」），它会在工作区里找。",
    aborted    = "已中断当前任务。",
    abortTimeout = "任务超时，已自动中断。",
    abortSent  = "已发出中断请求…",
    abortNothing = "当前没有正在执行的任务。",
    bridged    = "已连上本地桥 %s",
    testing    = "正在测试 LLM 连接...",
    backedUp   = "已备份：v%d \"%s\"  %s",
    autoBacked = "自动备份 v%d \"%s\"",
    snapFailed = "备份失败：%s",
    rolledBack = "已回滚到 v%d \"%s\"（%d/%d 个图层赛尔）",
    rollbackFailed = "回滚失败：%s",
    layersGone = "以下图层已不存在，未恢复：%s",
    noSnapshots= "还没有任何快照。",
    versionStack = "版本栈（%d）：",
    applied    = "已执行 %d 个算子，图层 %s —— %s",
    openedDoc  = "已打开新文档 %dx%d —— 复制到你的画布即可。%s",
    unknownAction = "未知命令：%s",
    fileDialogFailed = "文件对话框打不开（%s）；改用按钮下方的文件框。",
    loadedFixing = "已载入 %s，开始矫正（Perfect Pixel）...",
    reading    = "正在读取图片：%s",
    loadedSending = "已载入 %dx%d，发给桥做网格检测...",
    readFailed = "读取失败：%s",
    unknownMessage = "未知消息：%s",
    unexpectedFrame = "意外的二进制帧：%s",
    opsFailed  = "算子执行失败，画布未改动：%s",
    sizeDone   = "%s：%s -> %s",
    sizeNoop   = "%s：无需改动（%s）",
    sizeFailed = "尺寸操作失败，画布未改动：%s",
    artDrawn   = "已画 %d 像素（%dx%d），图层 %s",
    artClipped = "  （有 %d 像素落在画布外，已跳过）",
    artDoc     = "%s：%s",
    artFailed  = "作画失败，画布未改动：%s",
    blurry     = "结果如果发糊：原图可能不是像素画，或网格没检测准 —— 用显式网格尺寸重试。",
    importFailed = "导入失败：%s",
    importMismatch = "导入尺寸不匹配：收到 %d 字节，期望 %d",
    ready      = "AI 像素助手已就绪。改动前自动备份；Ctrl+Z 或 rollback 可回退。",
    tipMenu    = "输入 menu 或 菜单 打开命令表；↑/↓ 翻历史指令。",
    think      = "思考",
    buttons = {
      send = "发送", menu = "[菜单]", panel = "[小面板]",
      snapshot = "快照", rollback = "回滚", versions = "版本栈",
      reconnect = "重连", settings = "设置", fix = "矫正图片",
    },
    mini = {
      snapshot = "快照", rollback = "回滚", versions = "版本栈",
      fix = "矫正图片", bar = "切形态", settings = "设置", close = "收起",
    },
    builtins = {
      menu = "menu", ["菜单"] = "menu", ["命令"] = "menu", ["命令表"] = "menu",
      help = "help", ["?"] = "help", ["帮助"] = "help", ["说明"] = "help",
      cls = "clear", clear = "clear", ["清屏"] = "clear", ["清空"] = "clear",
      settings = "settings", config = "settings", ["设置"] = "settings", ["配置"] = "settings",
      snapshot = "snapshot", backup = "snapshot", ["快照"] = "snapshot", ["备份"] = "snapshot",
      rollback = "rollback", undo = "rollback", ["回滚"] = "rollback", ["撤销"] = "rollback",
      versions = "versions", history = "versions", ["版本"] = "versions", ["版本栈"] = "versions",
      fix = "fix", ["矫正"] = "fix",
      upload = "upload", open = "upload", ["选图"] = "upload", ["打开"] = "upload",
      reconnect = "reconnect", ["重连"] = "reconnect",
      stop = "abort", abort = "abort", ["停止"] = "abort", ["中断"] = "abort",
      deliver = "deliver", ["交付"] = "deliver", ["提交"] = "deliver",
      opendoc = "open_doc", ["打开文档"] = "open_doc", ["打开路径"] = "open_doc",
      bar = "bar", ["栏"] = "bar", ["边栏"] = "bar", ["侧栏"] = "bar", ["形态"] = "bar",
      ["终止"] = "abort", ["打断"] = "abort",
      exit = "@exit", quit = "@exit", close = "@exit", bye = "@exit",
      ["退出"] = "@exit", ["关闭"] = "@exit",
    },
  },
}

-- 命令表的行（keys/label/note 都本地化；顺序与 lib/agent.lua 的 action 对应）
local BUILDER = {
  en = function()
    return {
      { id = "snapshot",  keys = "S", label = "Snapshot current version",           note = "back up before AI edits" },
      { id = "rollback",  keys = "R", label = "Rollback last version",              note = "restore the newest backup" },
      { id = "versions",  keys = "V", label = "List version stack",                 note = "all snapshots so far" },
      { id = "fix",       keys = "F", label = "Fix image (Perfect Pixel)",          note = "grid-detect + resample" },
      { id = "upload",    keys = "U", label = "Pick image file",                    note = "choose a source image" },
      { id = "settings",  keys = "T", label = "Settings (Base URL / Model / Key)",  note = "LLM connection" },
      { id = "reconnect", keys = "C", label = "Reconnect to bridge",                note = "retry the local bridge" },
      { id = "abort",     keys = "X", label = "Interrupt the running task",         note = "same as pressing Esc" },
      { id = "deliver",   keys = "D", label = "Deliver the edit (workspace)",       note = "overwrite / keep / discard" },
      { id = "open_doc",  keys = "O", label = "Open a document by path",            note = "inside the workspace" },
      { id = "bar",       keys = "B", label = "Switch layout",                     note = "panel / bottom bar / side bar" },
      { id = "clear",     keys = "L", label = "Clear console",                      note = "wipe the scrollback" },
      { id = "help",      keys = "H", label = "Help / examples",                    note = "how to talk to the AI" },
    }
  end,
  zh_hans = function()
    return {
      { id = "snapshot",  keys = "S", label = "快照当前版本",            note = "AI 改动前自动备份" },
      { id = "rollback",  keys = "R", label = "回滚到上一个版本",        note = "恢复到最新备份" },
      { id = "versions",  keys = "V", label = "查看版本栈",              note = "列出现有快照" },
      { id = "fix",       keys = "F", label = "矫正图片（Perfect Pixel）", note = "检测网格并重采样" },
      { id = "upload",    keys = "U", label = "选择图片文件",            note = "挑选源图" },
      { id = "settings",  keys = "T", label = "设置（Base URL / 模型 / API Key）", note = "LLM 连接" },
      { id = "reconnect", keys = "C", label = "重连本地桥",              note = "重试 WebSocket" },
      { id = "abort",     keys = "X", label = "中断当前任务",            note = "和按 Esc 一样" },
      { id = "deliver",   keys = "D", label = "交付本次修改（工作区）",    note = "覆盖 / 保留 / 丢弃" },
      { id = "open_doc",  keys = "O", label = "按路径打开文档",          note = "工作区里的文件" },
      { id = "bar",       keys = "B", label = "切换形态",                note = "面板 / 底边栏 / 侧边栏" },
      { id = "clear",     keys = "L", label = "清屏",                    note = "清空回滚缓冲" },
      { id = "help",      keys = "H", label = "帮助 / 示例",             note = "怎么跟 AI 说话" },
    }
  end,
}

-- 「菜单」触发词（终端里敲这些 = 打开命令表）。查表匹配，不用模式或运算。
local MENU_WORDS = {
  menu = true, menue = true, meny = true,
  ["menü"] = true, ["menú"] = true, ["menù"] = true,
  ["菜单"] = true, ["菜單"] = true, ["選單"] = true, ["功能表"] = true, ["目錄"] = true,
  ["メニュー"] = true, ["メニュ"] = true, ["메뉴"] = true,
  ["меню"] = true, ["мэню"] = true,
}

-- 允许被剥掉的收尾标点（半角 + 全角 + 箭头）
local TAIL_CHARS = {
  ["!"] = true, ["?"] = true, ["？"] = true, ["！"] = true,
  ["."] = true, [","] = true, ["~"] = true,
  [";"] = true, [":"] = true, ["-"] = true, ["_"] = true,
  [">"] = true, ["»"] = true, ["—"] = true, ["–"] = true,
  ["、"] = true, ["！"] = true, ["？"] = true, ["。"] = true, ["，"] = true,
  ["；"] = true, ["："] = true,
}

-- 成对的包围符号（"【菜单】" / "[menu]" / "「菜单」" 两边都剥）
local PAIR_CLOSE = {
  ["["] = "]", ["("] = ")", ["{"] = "}", ["<"] = ">",
  ["【"] = "】", ["「"] = "」", ["（"] = "）", ["《"] = "》", ["〈"] = "〉",
}

-- 取最后一个 UTF-8 字符（不能直接 string.sub(-1)：会把多字节字符切碎）
local function lastChar(s)
  local n = #s
  if n == 0 then return "" end
  local i = utf8.offset(s, -1)
  if not i then return "" end
  return s:sub(i)
end

-- 全角 -> 半角（只做影响匹配的那些字符）
local FULLWIDTH = {
  ["（"] = "(", ["）"] = ")", ["［"] = "[", ["］"] = "]",
  ["｛"] = "{", ["｝"] = "}", ["＜"] = "<", ["＞"] = ">",
  ["！"] = "!", ["？"] = "?", ["．"] = ".", ["，"] = ",",
  ["；"] = ";", ["："] = ":", ["－"] = "-", ["　"] = " ",
}

-- 归一化：去 BOM、统一换行、全角转半角。
-- 注意 Lua 的 %s 不匹配 \r 与 BOM —— 带 BOM 的脚本/粘贴内容会整体匹配失败。
local function normalize(text)
  local s = tostring(text or "")
  s = s:gsub("^\239\187\191", "")      -- UTF-8 BOM
  s = s:gsub("[\r\n\t]", " ")
  for fw, hw in pairs(FULLWIDTH) do s = s:gsub(fw, hw) end
  return s
end

-- 剥掉一层"装饰"：首尾成对括号，或结尾标点。全程按 UTF-8 字符边界来。
local function stripOnce(s)
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  local n = #s
  if n == 0 then return s, false end

  local first = s:sub(1, 1)            -- 括号/标点都是单字节 ASCII，安全
  local last = lastChar(s)

  if PAIR_CLOSE[first] == last and n > #first + #last then
    return s:sub(2, n - #last), true
  end
  if TAIL_CHARS[last] then
    return s:sub(1, n - #last), true
  end
  if PAIR_CLOSE[first] then               -- 只有左括号也剥
    return s:sub(2), true
  end
  return s, false
end

----------------------------------------------------------------------
-- 语言
----------------------------------------------------------------------

local resolved = nil

-- 从任意语言线索里认语言：能处理 "zh_hans"、"en-US"、"LANG=zh_CN.UTF-8"，
-- 也认系统全名里的中文写法（"Windows 11 中文版"）。认不出返回 nil。
local function normalizeLang(raw)
  raw = tostring(raw or ""):lower()
  if raw == "" then return nil end
  if raw:find("chinese", 1, true) or raw:find("中文", 1, true) or raw:find("简体", 1, true) then
    return "zh_hans"
  end
  -- 在整串里找独立的语言标签：能认 "zh_hans" / "en-us" / "LANG=zh_CN.UTF-8" /
  -- "Windows 11 English" / "Chinese (Simplified)" 这些写法
  for token in raw:gmatch("[a-z]+") do
    if token == "zh" or token == "chinese" or token == "chs" then return "zh_hans" end
    if token == "en" or token == "english" then return "en" end
  end
  return nil
end

-- Aseprite 的首选项默认是 "en"（哪怕界面是中文），所以偏好值本身区分不了
-- "用户选过英文" 和 "没设过"；这里给"没设过"配一个系统语言兜底：
-- zh* 系统 / LANG=zh* -> 中文；其余 -> 英文。设置面板里改回英文的路径照常生效。
function i18n.resolve(prefValue, osLang)
  if resolved then return resolved end
  local prefRaw = tostring(prefValue or ""):lower()
  local fromOs = normalizeLang(osLang)
  if prefRaw:sub(1, 3) == "zh_" or prefRaw == "zh" then
    resolved = "zh_hans"
  elseif prefRaw ~= "" and prefRaw:sub(1, 2) == "en" then
    -- 首选项默认就是 "en"，区分不了"用户选了英文"和"没设过"。
    -- 读不到系统语言时（Windows 上 app.os.fullName 只有版本号、也没有 LANG 变量）
    -- 就按产品要求【默认中文】；想用英文可以在 Aseprite 首选项里选 English，
    -- 或在面板 Settings 里改。
    resolved = fromOs or "zh_hans"
  else
    resolved = fromOs or "zh_hans"        -- 什么都没读到：默认中文
  end
  return resolved
end

function i18n.lang()  return resolved or "zh_hans" end
function i18n.isZh()  return i18n.lang() == "zh_hans" end
function i18n.codes() local out = {}; for k in pairs(LOCALES) do out[#out+1] = k end; return out end

-- 只给测试用：清掉已解析的语言，好把每条解析分支都跑一遍
function i18n._resetLang()
  resolved = nil
end

-- 画布上的提示符（只用 Fusion Pixel 里确实有的字形，缺字形会掉到系统字体很难看）
function i18n.promptMark()
  return "AI >"
end

function i18n.t(key)
  local loc = LOCALES[i18n.lang()] or LOCALES.zh_hans
  local v = loc[key]
  if v == nil then v = LOCALES.zh_hans[key] end
  return v
end

-- 面板按钮文字（Send / 发送 ...）
function i18n.button(id)
  local loc = LOCALES[i18n.lang()] or LOCALES.zh_hans
  return (loc.buttons and loc.buttons[id]) or (LOCALES.zh_hans.buttons or {})[id] or id
end

-- 小面板格子标签
function i18n.miniLabel(id)
  local loc = LOCALES[i18n.lang()] or LOCALES.zh_hans
  return (loc.mini and loc.mini[id]) or (LOCALES.zh_hans.mini or {})[id] or id
end

-- 当前语言的菜单行
function i18n.menuCommands()
  local b = BUILDER[i18n.lang()] or BUILDER.zh_hans
  return b()
end

-- 帮助文本（多行用 \n 拼，别写成真换行：CRLF 文件里多行字符串会语法错误）
function i18n.helpText()
  return i18n.t("helpTitle") .. "\n" .. i18n.t("helpBody") .. "\n\n" .. i18n.t("helpBuiltin")
end

----------------------------------------------------------------------
-- 触发词
----------------------------------------------------------------------

-- 桥那边发来的状态是英文硬编码的，这里按表翻译（表里没有的原样显示）。
-- 有些状态带变量（"working (step 2)..." / "running crop..."），所以除了查表还要认前缀。
function i18n.statusText(text)
  local s = tostring(text or "")
  local loc = LOCALES[i18n.lang()] or LOCALES.zh_hans
  local map = loc.statusMap or {}
  if map[s] then return map[s] end

  local step = s:match("^working %(step (%d+)%)")
  if step then
    return string.format(loc.statusWorking or "working (step %d)...", tonumber(step) or 0)
  end
  local opname = s:match("^running (.+)$")
  if opname then
    opname = opname:gsub("%.+$", "")       -- 桥那边自带 "...", 免得叠成 "........"
    return string.format(loc.statusRunning or "running %s...", opname)
  end
  return s
end

-- 终端内建命令：返回 动作 id（"@exit" 表示退出控制台），不匹配返回 nil
function i18n.builtinAction(text)
  local s = normalize(text)
  if s == "" then return nil end
  for _ = 1, 8 do
    if #s <= 2 then break end        -- "?" 这种单字符命令别再剥了
    local next_s, changed = stripOnce(s)
    s = next_s
    if not changed then break end
  end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")

  -- 只对纯 ASCII 做小写：string.lower 是字节级的，会改坏多字节字符
  if s:find("^[%z\1-\127]+$") then s = s:lower() end
  local loc = LOCALES[i18n.lang()] or LOCALES.zh_hans
  local map = loc.builtins or LOCALES.zh_hans.builtins
  return map[s]
end

-- 兼容旧接口：这一行是不是"要看菜单"
function i18n.isMenuRequest(text)
  return i18n.builtinAction(text) == "menu"
    or MENU_WORDS[normalize(text):gsub("^%s+", ""):gsub("%s+$", "")] == true
end

-- 菜单打开时：这一行是不是"关闭菜单"？
function i18n.isMenuClose(text)
  local s = normalize(text):gsub("%s", "")
  if s == "" then return false end
  if s:find("^[%z\1-\127]+$") then s = s:lower() end
  if s == "x" or s == "q" or s == "esc" or s == "exit" or s == "quit" then return true end
  local closes = { "关闭", "关", "閉じる", "閉", "닫기", "닫", "закрыть", "закр", "退出", "取消" }
  for _, k in ipairs(closes) do
    if s:sub(1, #k) == k then return true end
  end
  return false
end

return i18n
