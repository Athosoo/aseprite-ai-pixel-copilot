-- packs/builtin/core -- 内核自带的视图壳与内建动作
-- 视图的【布局与绘制】归工作台（T2），内核不决定布局：core 只把 manifest 的声明
-- 注册进 registry，mount 把渲染交给工作台注入的 renderers[id]；注入缺失时退回占位视图，
-- 这样并行开发期间工作台没落地也不会把面板拖崩。
return function(ctx)
  local reg = ctx.registry
  local pack = ctx.pack or {}
  local renderers = ctx.renderers or {}
  local log = ctx.log or function() end

  for _, spec in ipairs(pack.views or {}) do
    local vid = tostring(spec.id)
    local title = tostring(spec.title or vid)
    local icon = tostring(spec.icon or "•")
    reg:define("view", {
      id = vid,
      title = title,
      icon = icon,
      order = tonumber(spec.order) or 100,
      mount = function(mctx)
        local ext = mctx and mctx.renderers or nil
        local renderer = (ext and ext[vid]) or renderers[vid]
        if type(renderer) == "function" then return renderer(mctx or ctx) end
        return { id = vid, title = title, icon = icon, placeholder = true }
      end,
    })
  end

  -- 内建动作只依赖 ctx，不依赖任何视图：账本自己在 kernel 里，读它就够
  reg:define("action", {
    id = "core.health",
    run = function(c, arg)
      local health = (c and c.ledger or ctx.kernel and ctx.kernel.ledger)
      if not health then return false, "no ledger" end
      local rows = {}
      for id, h in pairs(health:health()) do
        rows[#rows + 1] = string.format("%s calls=%d fails=%d msAvg=%.1f%s",
          id, h.calls, h.fails, h.msAvg, h.lastErr and (" lastErr=" .. h.lastErr) or "")
      end
      table.sort(rows)
      if #rows == 0 then
        log("没有已加载的能力包")
      else
        for _, row in ipairs(rows) do log(row) end
      end
      return true, rows
    end,
  })

  reg:define("action", {
    id = "core.journal",
    run = function(c, arg)
      local ledger = (c and c.ledger or ctx.kernel and ctx.kernel.ledger)
      if not ledger then return false, "no ledger" end
      local n = tonumber(arg) or 10
      local rows = {}
      for _, ev in ipairs(ledger:tail(n)) do
        local parts = { tostring(ev.event or "?") }
        if ev.id then parts[#parts + 1] = "id=" .. tostring(ev.id) end
        if ev.text then parts[#parts + 1] = tostring(ev.text) end
        if ev.err then parts[#parts + 1] = "err=" .. tostring(ev.err) end
        rows[#rows + 1] = table.concat(parts, " ")
        log(rows[#rows])
      end
      return true, rows
    end,
  })
end
