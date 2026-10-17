-- packs/builtin/ops/tests.lua -- 算子包自测（断言注册形状，语义仍由 tests/lua/ops_test.lua 覆盖）
return {
  {
    name = "manifest 声明的每个算子都注册成了 op",
    run = function(t)
      -- 名单照 manifest 抄一份：包自己说"我有这些"，测试就核对这些真的进了注册表
      local expected = {
        "replace_color", "erase_color", "erase_region", "fill_region", "outline",
        "despeckle", "palette_map", "quantize", "sharpen", "contrast",
      }
      for _, name in ipairs(expected) do
        t.ok(t.ctx.registry:get("op", name) ~= nil, "缺 op: " .. name)
      end
      t.eq(#t.ctx.registry:list("op"), #expected, "op 数量")
    end,
  },
  {
    name = "op 规格有 label 与 params 供画布页渲染",
    run = function(t)
      local spec = t.ctx.registry:get("op", "replace_color")
      t.ok(type(spec.label) == "string" and spec.label ~= "", "label")
      t.ok(type(spec.params) == "table", "params")
      t.eq(spec.params[1].name, "from", "第一个参数是 from")
    end,
  },
  {
    name = "op.run 在没有文档时返回 elided 而不是抛错",
    run = function(t)
      local spec = t.ctx.registry:get("op", "sharpen")
      local fakeHost = { active = function() return nil end }
      local res = spec.run(fakeHost, {})
      t.eq(res.changed, 0, "changed")
      t.ok(res.elided == true, "elided")
      t.ok(type(res.detail) == "string" and #res.detail > 0, "detail 要给可读原因")
    end,
  },
  {
    name = "op.run 把算子的异常折成 detail",
    run = function(t)
      local spec = t.ctx.registry:get("op", "replace_color")
      local fakeHost = {
        active = function() return { sprite = {}, frame = 1 } end,
        resolveCels = function() return nil, "the current layer has no editable cel; select a layer first" end,
      }
      local res = spec.run(fakeHost, { from = "#FF0000", to = "#00FF00" })
      t.eq(res.changed, 0, "changed")
      t.ok(res.detail:find("no editable cel", 1, true) ~= nil, "detail 要透传 host 的原因")
    end,
  },
}
