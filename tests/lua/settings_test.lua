-- tests/lua/settings_test.lua -- 设置对话框的"值搬运"部分
--
-- Dialog 本身在无头模式下开不起来，所以这里只测最要紧的部分：
--   * _values()  把输入框内容解析成 llm 表（数字解析不出来时【不传】，别把配置清成空）
--   * _fill()    重开对话框时把所有字段填回去（漏填 = 用户以为配置丢了）
--
--   aseprite -b --script tests/lua/settings_test.lua

local ROOT = os.getenv("ASE_PROJ")
if not ROOT or ROOT == "" then ROOT = "." end
package.path = package.path .. ";" .. ROOT .. "/extension/?.lua"

local settings = require("lib.settings")
local i18n = require("lib.i18n")

local passed, failed = 0, 0
local function check(name, cond, extra)
  if cond then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. (extra ~= nil and ("   <- " .. tostring(extra)) or ""))
  end
end

-- 假对话框：只记 modify 调用，不碰真的 Dialog
local function fakeDlg(data)
  local d = { data = data or {}, calls = {} }
  function d:modify(t)
    self.calls[#self.calls + 1] = t
    if t.id and t.text ~= nil then self.data[t.id] = t.text end
    if t.id and t.option ~= nil then self.data[t.id] = t.option end
  end
  return d
end

local function newSettings(opts)
  return settings.new(opts or {})
end

-- ---------------------------------------------------------------- _values
do
  local s = newSettings()
  s.dlg = fakeDlg{
    baseUrl = "https://api.example.com/v1",
    model = "deepseek-chat",
    apiKey = "sk-secret",
    wsRoot = "D:/work/art",
    barBg = "#2B2B2B",
    maxSteps = "30",
    contextTokens = "24000",
    temperature = "0.4",
    thinking = "high",
  }
  local llm, wsRoot, barBg = s:_values()
  check("baseUrl 原样传出", llm.baseUrl == "https://api.example.com/v1", llm.baseUrl)
  check("model 原样传出", llm.model == "deepseek-chat", llm.model)
  check("apiKey 原样传出（桥那边才落盘）", llm.apiKey == "sk-secret")
  check("步数解析成数字", llm.maxSteps == 30, llm.maxSteps)
  check("上下文解析成数字", llm.contextTokens == 24000, llm.contextTokens)
  check("温度解析成数字", llm.temperature == 0.4, llm.temperature)
  check("思考强度按字符串传", llm.thinking == "high", llm.thinking)
  check("工作区单独一个返回位", wsRoot == "D:/work/art", wsRoot)
  check("栏底色单独一个返回位", barBg == "#2B2B2B", barBg)
end

-- 数字填错/留空 -> 不传（桥保持原值），而不是变成 nil / NaN 把配置冲掉
do
  local s = newSettings()
  s.dlg = fakeDlg{ baseUrl = "u", model = "m", apiKey = "", maxSteps = "", contextTokens = "abc", temperature = "  " }
  local llm = s:_values()
  check("空步数不传", llm.maxSteps == nil)
  check("乱填的上下文不传", llm.contextTokens == nil)
  check("空温度不传", llm.temperature == nil)
  check("baseUrl 照旧传", llm.baseUrl == "u")
end

-- ---------------------------------------------------------------- 超时（界面填秒，桥收毫秒）
do
  local s = newSettings()
  s.dlg = fakeDlg{ baseUrl = "u", model = "m", apiKey = "", timeoutSec = "300", maxTurnSec = "900" }
  local llm = s:_values()
  check("单次超时按毫秒传给桥（界面填秒）", llm.timeoutMs == 300000, llm.timeoutMs)
  check("整轮超时按毫秒传给桥", llm.maxTurnMs == 900000, llm.maxTurnMs)

  local s2 = newSettings()
  s2.dlg = fakeDlg{ baseUrl = "u", model = "m", apiKey = "", timeoutSec = "2.5" }
  check("允许小数秒（2.5s -> 2500ms）", s2:_values().timeoutMs == 2500, s2:_values().timeoutMs)

  local s3 = newSettings()
  s3.dlg = fakeDlg{ baseUrl = "u", model = "m", apiKey = "", timeoutSec = "", maxTurnSec = "abc" }
  local llm3 = s3:_values()
  check("超时留空/乱填 -> 不传（桥保持原值，别把超时清成 0）",
    llm3.timeoutMs == nil and llm3.maxTurnMs == nil, llm3.timeoutMs)

  local s4 = newSettings()
  s4.dlg = fakeDlg{}
  s4.shown = true
  s4:_fill({ baseUrl = "u", model = "m", timeoutMs = 300000, maxTurnMs = 900000 })
  check("_fill 把毫秒换算回秒显示", s4.dlg.data.timeoutSec == "300", s4.dlg.data.timeoutSec)
  check("_fill 填了整轮超时", s4.dlg.data.maxTurnSec == "900", s4.dlg.data.maxTurnSec)

  local s5 = newSettings()
  s5.dlg = fakeDlg{}
  s5.shown = true
  s5:_fill(nil)
  check("没配置时单次超时给默认 180 秒", s5.dlg.data.timeoutSec == "180", s5.dlg.data.timeoutSec)
  check("没配置时整轮超时给默认 600 秒", s5.dlg.data.maxTurnSec == "600", s5.dlg.data.maxTurnSec)
end

-- 没有对话框也不炸（桥没连上时用户点设置）
do
  local s = newSettings()
  local ok, llm = pcall(function() return (s:_values()) end)
  check("没有对话框时 _values 返回空表而不是报错", ok and llm.baseUrl == "")
end

-- ---------------------------------------------------------------- _save
do
  local got = nil
  local s = newSettings{ onSave = function(llm, ws, bg) got = { llm = llm, ws = ws, bg = bg } end }
  s.dlg = fakeDlg{ baseUrl = "u", model = "m", apiKey = "k", wsRoot = "D:/ws", barBg = "#111111",
                   maxSteps = "12", contextTokens = "8000", temperature = "0", thinking = "low" }
  s:_save()
  check("onSave 被调用", got ~= nil)
  check("步数进了 llm 表", got and got.llm.maxSteps == 12)
  check("温度为 0 也要传（0 是合法值）", got and got.llm.temperature == 0, got and got.llm.temperature)
  check("工作区传给了 onSave 的第二个参数", got and got.ws == "D:/ws")
  check("栏底色传给了 onSave 的第三个参数", got and got.bg == "#111111")
  check("保存后 apiKey 输入框被清空（不回显）",
    (s.dlg.data.apiKey or "") == "", s.dlg.data.apiKey)
  check("保存后记住了工作区（下次重开显示这个）", s.opts.wsRoot == "D:/ws")
  check("保存后记住了栏底色", s.opts.barBg == "#111111")
end

-- ---------------------------------------------------------------- _fill
do
  local s = newSettings{ wsRoot = "D:/ws", barBg = "#222222" }
  s.dlg = fakeDlg{}
  s.shown = true
  s:_fill({ baseUrl = "u", model = "m", apiKeySet = true, apiKeyHint = "sk-****1234",
            maxSteps = 40, contextTokens = 32000, temperature = 0.7, thinking = "medium" })
  local d = s.dlg.data
  check("_fill 填了 baseUrl", d.baseUrl == "u", d.baseUrl)
  check("_fill 填了 model", d.model == "m", d.model)
  check("_fill 填了步数", d.maxSteps == "40", d.maxSteps)
  check("_fill 填了上下文", d.contextTokens == "32000", d.contextTokens)
  check("_fill 填了温度", d.temperature == "0.7", d.temperature)
  check("_fill 选了思考强度", d.thinking == "medium", d.thinking)
  check("_fill 填了工作区（否则一存就把工作区清掉）", d.wsRoot == "D:/ws", d.wsRoot)
  check("_fill 填了栏底色", d.barBg == "#222222", d.barBg)
  check("_fill 把 apiKey 输入框留空", (d.apiKey or "") == "", d.apiKey)

  -- 缺省值：桥还没发配置过来也不能填成空串
  local s2 = newSettings()
  s2.dlg = fakeDlg{}
  s2.shown = true
  s2:_fill(nil)
  check("没配置时步数给默认 24", s2.dlg.data.maxSteps == "24", s2.dlg.data.maxSteps)
  check("没配置时上下文给默认 16000", s2.dlg.data.contextTokens == "16000", s2.dlg.data.contextTokens)
  check("没配置时思考强度给 auto", s2.dlg.data.thinking == "auto", s2.dlg.data.thinking)

  -- 没显示时不该乱改（对话框没开）
  local s3 = newSettings()
  s3.dlg = fakeDlg{}
  s3.shown = false
  s3:_fill({ baseUrl = "zzz" })
  check("对话框没开时 _fill 不写值", s3.dlg.data.baseUrl == nil)
end

-- ---------------------------------------------------------------- 文案
do
  i18n._resetLang()
  local keys = { "settingsTitle", "advTitle", "advSteps", "advContext", "advTemp",
                 "advThinking", "advHint", "advTimeout", "advTurn", "stepLimit", "thinkingDropped",
                 "ctxCleared", "ctxRestored", "ctxCompacted", "ctxEmpty", "ctxStats",
                 "llmTimeout", "abortTimeout",
                 "wsTitle", "wsHint", "barBgHint", "btnSave", "btnTest", "btnClose" }
  local missing = {}
  for _, k in ipairs(keys) do
    local v = i18n.t(k)
    if type(v) ~= "string" or v == "" or v == k then missing[#missing + 1] = k end
  end
  check("设置窗/上下文的文案键都在", #missing == 0, table.concat(missing, ","))
end

print(string.format("\n==== settings_test: %d 通过, %d 失败 ====", passed, failed))
if failed > 0 then os.exit(1) end
