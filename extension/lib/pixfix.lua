-- lib/pixfix.lua -- 把矫正好的像素"就地"落进当前文档
--
-- 为什么单独一个模块：perfect_pixel 的结果有两条落地路径（桥直接送来的
-- import_image / 面板上的「应用这个结果」按钮），两条必须是同一份像素代码。
-- 写两套的结局是"按钮贴的图和模型贴的图不一样"，而且改一处漏一处。
--
-- 这一层只管【像素与画布】，不管快照 / 工作区门禁 / 日志 / 回执：
--   * 落在哪张 sprite、以什么名字建层        -> 因为要复用工作区里那份"副本"
--   * versions.push 快照、prepareEdit 门禁   -> 由 agent.lua 负责（和 runOps 同一套纪律）
--
-- 落地语义（用户拍板）：
--   * 结果一律贴在 (0,0)，放进【新增】的一个图层，原图层像素一个都不动；
--   * 结果比画布小 -> 画布不动，多余的空白留在右下；
--   * 结果比画布大 -> 先把画布扩到装得下（top-left 锚点：原有内容不动，
--     新增的是右边和下边），**不裁掉任何像素**；
--   * 整件事一个事务 = 一次 Ctrl+Z。

local pixfix = {}

-- 图层名必须是 ASCII（和 draw_art 的图层名同一条规矩，见 bridge 的 isAsciiName）。
-- 空格和 x 都是 ASCII，安全。
function pixfix.layerName(w, h)
  return string.format("PP %dx%d", math.floor(w), math.floor(h))
end

-- data: RGBA8 原始字节，长度必须正好 w*h*4（小了会画进未初始化的内存，大了会被静默截断）
function pixfix.applyFixedRGBA(spr, data, w, h, opts)
  opts = opts or {}
  if not spr then return { ok = false, error = "no document is open" } end
  w = math.floor(tonumber(w) or 0)
  h = math.floor(tonumber(h) or 0)
  if w < 1 or h < 1 then
    return { ok = false, error = string.format("bad result size %dx%d", w, h) }
  end
  if type(data) ~= "string" or #data ~= w * h * 4 then
    return { ok = false, error = string.format("result size mismatch: got %d bytes, expected %d",
      type(data) == "string" and #data or -1, w * h * 4) }
  end

  local oldW, oldH = spr.width, spr.height
  local name = opts.name or pixfix.layerName(w, h)

  -- 新图层名要唯一：同一个文档连续矫正两次会撞名，撞了 Aseprite 自己加后缀，
  -- 但那样回执里的名字和实际层名对不上 —— 干脆自己先找到没被占用的那个。
  local taken = {}
  for i = 1, #spr.layers do taken[spr.layers[i].name] = true end
  if taken[name] then
    local n = 2
    while taken[string.format("%s (%d)", name, n)] do n = n + 1 end
    name = string.format("%s (%d)", name, n)
  end

  local ok, res = pcall(function()
    local out
    app.transaction("AI: apply fixed image", function()
      -- 先扩画布：内容按 top-left 摆，所以 (0,0) 还是原来的 (0,0)
      if w > oldW or h > oldH then
        app.command.CanvasSize{
          ui = false,
          bounds = Rectangle(0, 0, math.max(oldW, w), math.max(oldH, h)),
        }
      end

      local layer = spr:newLayer()
      layer.name = name

      -- 显式给新图层建 cel + image（不靠 newCel 的默认图，免得颜色模式/尺寸碰运气）
      local frame = app.activeFrame or 1
      local img = Image(spr.width, spr.height, spr.colorMode)
      spr:newCel(layer, frame, img, Point(0, 0))

      -- 结果先落在 RGB 暂存图上（字节就是 RGBA8），再 SRC 画过去：
      -- 索引色 / 灰度文档也能落地（Aseprite 自己按调色板映射），不用为每种模式各写一份。
      local scratch = Image(w, h, ColorMode.RGB)
      scratch.bytes = data
      img:drawImage(scratch, Point(0, 0), 255, BlendMode.SRC)

      out = {
        ok = true,
        layer = name,
        layerIsNew = true,
        at = { x = 0, y = 0 },
        result = string.format("%dx%d", w, h),
        canvasFrom = string.format("%dx%d", oldW, oldH),
        canvas = string.format("%dx%d", spr.width, spr.height),
        expanded = (spr.width > oldW or spr.height > oldH),
        frame = frame,
      }
    end)
    return out
  end)

  if not ok then
    return { ok = false, error = tostring(res) }
  end
  res.op = "apply_fixed"
  return res
end

return pixfix
