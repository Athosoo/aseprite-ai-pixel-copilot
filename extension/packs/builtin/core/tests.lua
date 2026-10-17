-- packs/builtin/core/tests.lua -- 核心外壳自测
-- 跑法：kernel.runPackTests(kernel, pack)（见 kernel/init.lua 与 tests/lua/kernel_test.lua）
-- 断言只经 t 拿到手：t.ctx 是该包的加载上下文，t.ok/t.eq 是断言。
return {
  {
    name = "七个内建视图都注册了 view 规格",
    run = function(t)
      local views = t.ctx.registry:list("view")
      t.eq(#views, 7, "view 数量")
      t.eq(views[1].id, "console", "order 最小的应当是会话页")
      t.eq(views[1].icon, "▤", "会话页图标")
    end,
  },
  {
    name = "view 的 order 按 manifest 稳定排序",
    run = function(t)
      local views = t.ctx.registry:list("view")
      for i = 2, #views do
        t.ok(views[i - 1].order <= views[i].order, "order 必须非降序")
      end
    end,
  },
  {
    name = "mount 在没有渲染器时退回占位视图而不是报错",
    run = function(t)
      local spec = t.ctx.registry:get("view", "canvas")
      local v = spec.mount({})
      t.eq(v.id, "canvas", "占位视图 id")
      t.ok(v.placeholder == true, "没有渲染器时应当是占位视图")
    end,
  },
  {
    name = "mount 优先用注入的渲染器",
    run = function(t)
      local spec = t.ctx.registry:get("view", "console")
      local v = spec.mount({ renderers = { console = function() return { id = "console", kind = "real" } end } })
      t.eq(v.kind, "real", "注入渲染器应当被调用")
    end,
  },
  {
    name = "两个内建动作都注册了",
    run = function(t)
      local reg = t.ctx.registry
      t.ok(reg:get("action", "core.health") ~= nil, "core.health")
      t.ok(reg:get("action", "core.journal") ~= nil, "core.journal")
    end,
  },
}
