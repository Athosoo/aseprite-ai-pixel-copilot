# v0.6.1 发布说明

> 定位：**把算子参数变成机器可读的契约**，并让 `dsh-plugin-aseprite` 能独立工作
> （不依赖本仓库 checkout）。用户可见行为不变 —— 这是基础设施版本。

---

## 一、上游改了什么

1. **`extension/lib/ops.lua` 的 OPS 表新增 `params` 元数据**（10 个算子 / 27 个参数）。
   字段：`name / type / required / default / desc`，`type` ∈
   `color | int | number | bool | object | region`。
2. **新增 `ops.manifest()`**：返回机器可读清单（名字 + 描述 + 参数 schema）。
   **OPS 表是唯一真源** —— 工具 schema、插件清单、系统提示都从它生成，不再手写第二份。
3. **`ops.describe()` 带出参数摘要**（`[params: amount:number=1.3, region:region]`），
   系统提示因此能告诉模型每个算子吃什么参数、默认值是多少。
4. `ops_test` **97 → 104**：新增 manifest 条数 / 每个参数有 name+type+desc /
   `replace_color.from/to` 与 `fill_region.color` 必填 / contrast 1.3 / quantize 64 /
   region 覆盖 10 个算子 / describe 带参数摘要。

## 二、下游（dsh-plugin-aseprite）因此能做的

- `test/sync-ops.mjs`：从本仓库 vendor `ops.lua` + `util.lua`，再用真 Aseprite 跑
  `ops.manifest()` 生成 `lib/vendor/ops.manifest.json`，同时记录上游 commit 与文件 sha256。
- `test/manifest.mjs`：vendor 哈希 / 清单条数 / 算子名单与源码一致 —— 手改 vendor 不重跑 sync 会立刻红。
- 插件侧 P1b 完成：7 个工具、覆盖前自动备份（同源留 10 份、失败即中止）、GUI 冲突提示、
  算子清单从 manifest 动态生成、**插件不再依赖 `D:/PraticleTool/Aseprite-AI` 这份 checkout**。

## 三、怎么验证

```bash
# 上游
"D:/PraticleTool/Aseprite/aseprite.exe" -b --script tests/lua/ops_test.lua   # 104 通过

# 插件
cd D:/PraticleTool/dsh-plugin-aseprite
node test/config.mjs     # 22
node test/manifest.mjs   # 10
node test/smoke.mjs      # 18（需要真 Aseprite）
```

## 四、已知边界

- 只补了参数元数据，**工具 schema 的 enum 仍是桥侧手写的**（`bridge/src/tools.mjs`）；
  下一步可以让桥也从 `ops.manifest()` 生成 enum，彻底去掉第二份名单。
- 插件仍只改「磁盘上的文件」；GUI 里未保存的画布要等 P3 的实时通道。
