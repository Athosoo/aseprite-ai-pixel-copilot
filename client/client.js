/**
 * Aseprite Workbench -- client bundle (P0.5 hello).
 * Outer shell must be window.__ModuleLoader__.load({ id, factory }); react comes from require.
 * 尽量少依赖：不用 locale、不用 icons，注册失败也只记 console.error，不影响宿主。
 */
window.__ModuleLoader__.load({
  id: "dsh-plugin-aseprite",
  factory: (require) => {
    const module = { exports: {} };
    const exports = module.exports;
    const react = require("react");

    const PANEL_ID = "aseprite-workbench";
    const NS = "dsh-plugin-aseprite";

    function PanelListLabel() {
      return react.createElement("span", null, "Aseprite");
    }

    function PanelPage() {
      return react.createElement(
        "div",
        { style: { padding: "24px 28px" } },
        react.createElement("h2", { style: { margin: "0 0 8px", fontSize: "18px" } }, "Aseprite Workbench"),
        react.createElement(
          "p",
          { style: { margin: 0, opacity: 0.75 } },
          "插件已加载：侧边栏入口 + 主区页面都走通了。下一步接画布预览与算子。"
        )
      );
    }

    function apply(ctx) {
      const log = (m) => { try { console.error("[aseprite] " + m); } catch (e) {} };
      try {
        ctx.slots.inject("sidebar.panellist", () =>
          ctx.slots.register(
            { name: "sidebar.panellist", id: PANEL_ID, order: 40, label: () => "Aseprite" },
            PanelListLabel
          )
        );
        log("panellist registered");
      } catch (e) {
        log("panellist register failed: " + (e && e.message));
      }
      try {
        ctx.slots.inject("main", () =>
          ctx.slots.register({ name: "main", key: PANEL_ID }, PanelPage)
        );
        log("main page registered");
      } catch (e) {
        log("main page register failed: " + (e && e.message));
      }
    }

    exports.name = NS;
    exports.apply = apply;
    exports.inject = ["slots"];
    return module.exports;
  }
});
