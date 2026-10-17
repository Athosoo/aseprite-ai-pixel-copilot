-- packs/builtin/ops -- 把 lib/ops.lua 的算子注册成 op 能力
-- 只包装、不改写：名字、参数、语义全由 lib/ops.lua 决定（D4：8+2 个算子签名不变）。
-- 这里只做两件事：
--   1) 目标 cel 解析走 host:resolveCels（语义与 v0.5.9 的 ops.resolveCels 一致）；
--   2) 任何错误都折成 { changed = 0, elided = true, detail = err }，交给调用方自愈。
local LABELS = {
  replace_color = "换色",
  erase_color = "擦色",
  erase_region = "清空矩形",
  fill_region = "填色",
  outline = "描边",
  despeckle = "清杂点",
  palette_map = "调色板映射",
  quantize = "自动减色",
  sharpen = "锐化边缘",
  contrast = "加强明暗对比",
}

-- 参数声明只服务于 UI 的表单渲染（docs/ui-v1.0.md §5 画布页），
-- 校验仍然由 lib/ops.lua 自己负责 —— 这里不复制它的规则。
local PARAMS = {
  replace_color = { { name = "from", type = "color", required = true, hint = "#RRGGBB" },
                    { name = "to", type = "color", required = true, hint = "#RRGGBB 或 #RRGGBBAA" },
                    { name = "tolerance", type = "integer", hint = "默认 0" } },
  erase_color   = { { name = "color", type = "color", required = true, hint = "#RRGGBB" },
                    { name = "tolerance", type = "integer", hint = "默认 0" } },
  erase_region  = { { name = "region", type = "region", required = true, hint = "x,y,w,h" } },
  fill_region   = { { name = "region", type = "region", required = true, hint = "x,y,w,h" },
                    { name = "color", type = "color", required = true, hint = "#RRGGBB" } },
  outline       = { { name = "color", type = "color", required = true, hint = "#RRGGBB" } },
  despeckle     = { { name = "maxCluster", type = "integer", hint = "默认 1" } },
  palette_map   = { { name = "map", type = "map", required = true, hint = '{ "#old": "#new" }' } },
  quantize      = { { name = "colors", type = "integer", required = true, hint = "2-256" } },
  sharpen       = { { name = "amount", type = "number", hint = "默认 1.0" },
                    { name = "threshold", type = "integer", hint = "0-255，默认 0" } },
  contrast      = { { name = "amount", type = "number", hint = "默认 1.3" },
                    { name = "pivot", type = "integer", hint = "默认 128" } },
}

-- 能力包跑在沙箱里（没有 require / package），核心模块只能由宿主的 shared 表交进来，
-- 这样"算子实现在内核、注册在包里"的分层才不被迫打破。
local function loadOps(ctx)
  local shared = ctx.shared
  if type(shared) == "table" and type(shared.ops) == "table" then return shared.ops end
  return nil, "host did not provide ctx.shared.ops (lib/ops.lua)"
end

return function(ctx)
  local reg = ctx.registry
  local log = ctx.log or function() end
  local opsModule, lerr = loadOps(ctx)
  if not opsModule then
    error("ops pack: " .. tostring(lerr))
  end

  local failed = {}
  for _, name in ipairs(opsModule.names) do
    local opName = tostring(name)
    local ok, err = reg:define("op", {
      name = opName,
      label = LABELS[opName] or opName,
      params = PARAMS[opName] or {},
      run = function(host, params)
        params = params or {}
        local active = host:active()
        if not active then
          return { changed = 0, elided = true, detail = "no document is open" }
        end
        local cels, rerr = host:resolveCels(active.sprite, active.frame, params.layers)
        if not cels then
          return { changed = 0, elided = true, detail = rerr }
        end
        local single = {}
        for k, v in pairs(params) do single[k] = v end
        single.op = opName
        single.layers = nil

        local okRun, rep = pcall(opsModule.run, { single }, "op " .. opName, cels)
        if not okRun then
          return { changed = 0, elided = true, detail = tostring(rep) }
        end
        local first = rep.ops and rep.ops[1] or nil
        local changed = (first and first.changed) or 0
        return {
          changed = changed,
          elided = false,
          detail = string.format("%s: %d px", opName, changed),
          extra = first and first.extra or nil,
        }
      end,
    })
    if not ok then failed[#failed + 1] = opName .. ": " .. tostring(err) end
  end

  if #failed > 0 then
    error("ops pack registered with errors: " .. table.concat(failed, "; "))
  end
  log("ops pack: %d 个算子已注册", #opsModule.names)
end
