-- kernel/host.lua -- 唯一允许碰 app./Sprite{/Image{ 的地方（§3.3）
-- 铁律：算子与视图里不得出现 app. / Sprite{ / Image{ 字面量，一律走这里。
-- 这是把 Lua 侧做成「可无头单测」的唯一前提。
local Host = {}
Host.__index = Host

function Host.new(app, opts)
  opts = opts or {}
  return setmetatable({
    app = app or _G.app,
    -- lib.versions 是单例模块（接口不变），由 init() 注入 —— require 只在 init() 里活，
    -- 内核模块自己不能 require。
    versionsModule = opts.versions,
    uiAlert = opts.alert,
    uiNotify = opts.notify,
    uiFilePicker = opts.filePicker,
  }, Host)
end

function Host:active()
  local app = self.app
  local spr = app.activeSprite
  if not spr then return nil end
  local cel = app.activeCel
  local layer = app.activeLayer or (cel and cel.layer) or nil
  local frame = (cel and cel.frameNumber) or 1
  local name = "(未命名)"
  if spr.filename ~= "" then
    local ok, base = pcall(function() return app.fs.fileName(spr.filename) end)
    if ok and base and base ~= "" then name = base end
  end
  return {
    document = spr,
    sprite = spr,
    layer = layer,
    frame = frame,
    cel = cel,
    image = cel and cel.image or nil,
    name = name,
  }
end

-- 语义与 v0.5.9 的 lib/ops.lua:resolveCels 逐条一致，只把 error 换成 nil, err
-- （算子不该因为"名字打错"把整个调用栈炸掉，模型需要拿到错误文本自愈）。
--   nil / ""       -> 当前活动 cel
--   "all"          -> 当前帧里所有有可编辑 cel 的层
--   { names... }   -> 多个层名
--   "base"         -> 单个层名
function Host:resolveCels(sprite, frame, spec)
  sprite = sprite or self.app.activeSprite
  if not sprite then return nil, "no document is open" end
  frame = frame or 1

  local names = {}
  for _, l in ipairs(sprite.layers) do names[#names + 1] = l.name end

  local wanted = {}
  if spec == nil or spec == "" then
    local c = self.app.activeCel
    if not c or not c.image then
      return nil, "the current layer has no editable cel; select a layer first"
    end
    wanted[1] = c
  elseif type(spec) == "string" and spec:lower() == "all" then
    for _, l in ipairs(sprite.layers) do
      local c = l:cel(frame)
      if c and c.image then wanted[#wanted + 1] = c end
    end
    if #wanted == 0 then return nil, "no layer in this document has an editable cel" end
  else
    local list = (type(spec) == "table") and spec or { spec }
    for _, one in ipairs(list) do
      local want = tostring(one)
      local hit = nil
      for _, l in ipairs(sprite.layers) do
        if l.name == want then hit = l break end
      end
      if not hit then
        -- 层名打错时把本文档的层名一起报出去，模型下一轮能自己纠正
        return nil, string.format("no layer named %q; layers in this document: %s",
          want, table.concat(names, ", "))
      end
      local c = hit:cel(frame)
      if not c or not c.image then
        return nil, string.format("layer %q has no editable cel in this frame", want)
      end
      wanted[#wanted + 1] = c
    end
  end

  -- 去重不能用 cel userdata 当 key：同一个 cel 每次 :cel() 拿到的是不同包装对象，
  -- 用身份比较等于不去重（同一个层会被算子改两遍）。用"层名+帧号"这个稳定键。
  local seen, out = {}, {}
  for _, c in ipairs(wanted) do
    local key = tostring(c.layer and c.layer.name or "?") .. "#" .. tostring(c.frameNumber)
    if not seen[key] then seen[key] = true; out[#out + 1] = c end
  end
  return out
end

function Host:apply(label, fn)
  if type(fn) ~= "function" then return false, "apply: fn must be a function" end
  if not self.app.activeSprite then return false, "no document is open" end
  local ok, err = pcall(function()
    self.app.transaction("AI: " .. tostring(label or "编辑"), function() return fn(self) end)
  end)
  if not ok then return false, tostring(err) end
  return true
end

-- 游离 Image 上算完 -> drawImage(SRC) 一次写回：只有这条路径会记撤销（约束 1）
function Host:drawCells(cels, imageFn)
  if type(cels) ~= "table" or type(imageFn) ~= "function" then return 0 end
  local changed = 0
  for _, cel in ipairs(cels) do
    local target = cel and cel.image or nil
    if target then
      local scratch = Image(target.width, target.height, target.colorMode)
      scratch.bytes = target.bytes
      local n = imageFn(scratch, cel) or 0
      if n > 0 then
        target:drawImage(scratch, Point(0, 0), 255, BlendMode.SRC)
        changed = changed + n
      end
    end
  end
  return changed
end

function Host:openDocument(path)
  if type(path) ~= "string" or path == "" then return nil, "openDocument: path is required" end
  local ok, err = pcall(function() self.app.open(path) end)
  if not ok then return nil, tostring(err) end
  local spr = self.app.activeSprite
  if not spr then return nil, "failed to open " .. path end
  return spr
end

function Host:alert(text)
  if self.uiAlert then return self.uiAlert(tostring(text)) end
  local ok = pcall(function() self.app.alert(tostring(text)) end)
  return ok
end

function Host:notify(msg, tone)
  if self.uiNotify then return self.uiNotify(tostring(msg), tone) end
  -- 没有注入 UI 时退回 alert：headless 下 app.alert 是空操作，不会崩
  local ok = pcall(function() self.app.alert(tostring(msg)) end)
  return ok
end

function Host:filePicker(cb)
  if self.uiFilePicker then return self.uiFilePicker(cb) end
  local ok, err = pcall(function() self.app.command.OpenFile() end)
  if not ok then return false, tostring(err) end
  -- 约束 38：OpenFile 只返回布尔值，文件名要事后从 activeSprite 读
  local spr = self.app.activeSprite
  local path = spr and spr.filename or nil
  if type(cb) == "function" and path and path ~= "" then pcall(cb, path) end
  return path ~= nil and path ~= "", path
end

function Host:versions()
  if not self.versionsModule then return nil, "versions module was not injected (kernel.host opts.versions)" end
  return self.versionsModule
end

return Host
