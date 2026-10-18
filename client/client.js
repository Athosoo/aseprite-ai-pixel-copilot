/**
 * Aseprite Workbench -- client bundle (P2).
 * 外壳必须是 window.__ModuleLoader__.load({ id, factory })，react 由 require 注入。
 *
 * 三块：文件列表 / 画布预览 / 算子台。数据全部走宿主路由：
 *   POST /aseprite/api/<method>   （JSON）
 *   GET  /aseprite/media?path=…   （PNG 字节）
 * 算子跑完自动刷新预览，并把一行操作回显到当前会话（宿主侧 agent.inject）。
 */
window.__ModuleLoader__.load({
  id: "dsh-plugin-aseprite",
  factory: (require) => {
    const module = { exports: {} };
    const exports = module.exports;
    const react = require("react");

    const PANEL_ID = "aseprite-workbench";
    const NS = "dsh-plugin-aseprite";

    /** 相对页面 base 解析宿主路由（反向代理前缀安全）。 */
    function routeUrl(path) {
      try {
        return new URL(path.replace(/^\/+/, ""), document.baseURI).href;
      } catch (e) {
        return path;
      }
    }

    async function api(method, args) {
      const res = await fetch(routeUrl("aseprite/api/" + method), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(args || {})
      });
      let payload = null;
      try { payload = await res.json(); } catch (e) { payload = null; }
      if (!payload) throw new Error("bad response (" + res.status + ")");
      if (!payload.ok) throw new Error(payload.error || "request failed");
      return payload.value;
    }

    function mediaUrl(path) {
      return routeUrl("aseprite/media?path=" + encodeURIComponent(path) + "&t=" + Date.now());
    }

    /** 当前会话 id：先问 sidebarRight.mounted（官方认可的"屏幕上那个会话"），再退回 sessions 列表。 */
    function resolveSessionId(ctx) {
      const get = (name) => {
        try {
          if (ctx && typeof ctx.get === "function") return ctx.get(name);
          return ctx ? ctx[name] : undefined;
        } catch (e) { return undefined; }
      };
      try {
        const mounted = get("sidebarRight") && get("sidebarRight").mounted;
        const id = mounted && typeof mounted.getSnapshot === "function" ? mounted.getSnapshot() : undefined;
        if (typeof id === "string" && id) return id;
      } catch (e) {}
      try {
        const list = get("sessions") && get("sessions").list;
        const snap = list && typeof list.getSnapshot === "function" ? list.getSnapshot() : undefined;
        const id = snap && (snap.current || snap.active);
        if (typeof id === "string" && id) return id;
      } catch (e) {}
      return undefined;
    }

    /** 面板的默认参数：取 manifest 里带 default 的参数，region 这类结构性参数不传。 */
    function defaultParams(op) {
      const out = {};
      for (const p of op.params || []) {
        if (p.name === "region") continue;
        if (p.default !== undefined) out[p.name] = p.default;
      }
      return out;
    }

    const S = {
      wrap: { padding: "18px 22px", display: "flex", flexDirection: "column", gap: "12px", height: "100%", boxSizing: "border-box" },
      head: { display: "flex", alignItems: "baseline", gap: "12px", flexWrap: "wrap" },
      title: { margin: 0, fontSize: "17px", fontWeight: 600 },
      path: { fontFamily: "ui-monospace, monospace", fontSize: "11px", opacity: 0.6, wordBreak: "break-all" },
      cols: { display: "flex", gap: "12px", flex: 1, minHeight: 0 },
      card: { border: "1px solid rgba(128,128,128,.25)", borderRadius: "8px", minHeight: 0, display: "flex", flexDirection: "column" },
      cardHead: { padding: "7px 10px", borderBottom: "1px solid rgba(128,128,128,.2)", fontSize: "11px", textTransform: "uppercase", letterSpacing: ".04em", opacity: 0.65 },
      list: { overflow: "auto", padding: "4px 0", flex: 1 },
      row: { padding: "5px 10px", fontSize: "12px", cursor: "pointer", display: "flex", justifyContent: "space-between", gap: "8px", border: "none", background: "none", color: "inherit", width: "100%", textAlign: "left" },
      rowOn: { background: "rgba(90,140,255,.18)" },
      dim: { opacity: 0.55, fontSize: "11px" },
      ops: { display: "grid", gridTemplateColumns: "1fr 1fr", gap: "6px", padding: "8px", overflow: "auto", flex: 1, alignContent: "start" },
      op: { padding: "7px 8px", fontSize: "12px", borderRadius: "6px", border: "1px solid rgba(128,128,128,.3)", background: "rgba(128,128,128,.1)", color: "inherit", cursor: "pointer", textAlign: "left" },
      btn: { padding: "5px 10px", fontSize: "12px", borderRadius: "6px", border: "1px solid rgba(128,128,128,.3)", background: "rgba(128,128,128,.1)", color: "inherit", cursor: "pointer" },
      preview: { flex: 1, minHeight: 0, display: "flex", alignItems: "center", justifyContent: "center", padding: "10px", overflow: "auto", background: "repeating-conic-gradient(rgba(128,128,128,.1) 0% 25%, transparent 0% 50%) 50% / 16px 16px" },
      img: { maxWidth: "100%", maxHeight: "100%", imageRendering: "pixelated" },
      log: { margin: 0, fontSize: "11px", fontFamily: "ui-monospace, monospace", whiteSpace: "pre-wrap", opacity: 0.8, maxHeight: "72px", overflow: "auto" },
      err: { color: "#d9534f", fontSize: "12px" }
    };

    function PanelListLabel() {
      return react.createElement("span", null, "Aseprite");
    }

    function makePanelPage(ctx) {
      return function PanelPage() {
        const [state, setState] = react.useState(null);
        const [error, setError] = react.useState("");
        const [selected, setSelected] = react.useState(null);
        const [preview, setPreview] = react.useState(null);
        const [busy, setBusy] = react.useState("");
        const [log, setLog] = react.useState([]);

        const push = react.useCallback((line) => {
          setLog((prev) => [new Date().toLocaleTimeString() + "  " + line, ...prev].slice(0, 40));
        }, []);

        const refresh = react.useCallback(async (keep) => {
          setBusy("refresh");
          try {
            const s = await api("state");
            setState(s);
            setError("");
            if (!keep && s.files.length) setSelected(s.files[0].name);
            return s;
          } catch (e) {
            setError(e.message || String(e));
            return null;
          } finally {
            setBusy("");
          }
        }, []);

        const loadPreview = react.useCallback(async (name) => {
          if (!name) return;
          try {
            const r = await api("preview", { file: name });
            setPreview({ url: mediaUrl(r.path), name, via: r.via });
          } catch (e) {
            setError(e.message || String(e));
          }
        }, []);

        react.useEffect(() => { refresh(); }, [refresh]);
        react.useEffect(() => { if (selected) loadPreview(selected); }, [selected, loadPreview]);

        const runOp = react.useCallback(async (op) => {
          if (!selected) return;
          setBusy(op.name);
          setError("");
          try {
            const r = await api("apply", {
              file: selected,
              op: op.name,
              params: defaultParams(op),
              sessionId: resolveSessionId(ctx)
            });
            if (!r.ok) {
              push("✗ " + (r.error || "失败"));
              setError(r.error || "失败");
            } else {
              const echoed = r.echo && r.echo.echoed ? "已回显" : "未回显（" + ((r.echo && r.echo.reason) || "无活动会话") + "）";
              push("✓ " + r.ops + " → " + r.text + " · " + echoed);
              await loadPreview(selected);
            }
          } catch (e) {
            setError(e.message || String(e));
            push("✗ " + (e.message || e));
          } finally {
            setBusy("");
          }
        }, [selected, ctx, loadPreview, push]);

        const doExport = react.useCallback(async () => {
          if (!selected) return;
          setBusy("export");
          try {
            const r = await api("export", { file: selected, sessionId: resolveSessionId(ctx) });
            push("导出 → " + r.out);
          } catch (e) { setError(e.message || String(e)); }
          finally { setBusy(""); }
        }, [selected, ctx, push]);

        const doOpen = react.useCallback(async () => {
          if (!selected) return;
          try { await api("open", { file: selected }); push("已用 Aseprite 打开 " + selected); }
          catch (e) { setError(e.message || String(e)); }
        }, [selected, push]);

        const files = state ? state.files : [];
        const ops = state ? state.ops : [];

        return react.createElement(
          "div",
          { style: S.wrap },
          react.createElement(
            "div",
            { style: S.head },
            react.createElement("h2", { style: S.title }, "Aseprite Workbench"),
            react.createElement("button", { style: S.btn, onClick: () => refresh(true), disabled: !!busy }, "刷新"),
            react.createElement("button", { style: S.btn, onClick: doOpen, disabled: !selected }, "用 Aseprite 打开"),
            react.createElement("button", { style: S.btn, onClick: doExport, disabled: !selected || !!busy }, "导出 PNG"),
            state ? react.createElement("span", { style: S.path }, state.workspace) : null
          ),
          state && !state.aseprite
            ? react.createElement("div", { style: S.err }, "找不到 Aseprite。检查配置里的 aseprite 路径（配置文件：" + state.config + "）")
            : null,
          error ? react.createElement("div", { style: S.err }, error) : null,
          react.createElement(
            "div",
            { style: S.cols },
            react.createElement(
              "div",
              { style: Object.assign({ width: "210px" }, S.card) },
              react.createElement("div", { style: S.cardHead }, "文件"),
              react.createElement(
                "div",
                { style: S.list },
                files.length === 0
                  ? react.createElement("div", { style: Object.assign({ padding: "8px 10px" }, S.dim) },
                      "工作区里没有 .ase/.aseprite/.png。把文件放到上面那个目录即可。")
                  : files.map((f) => react.createElement(
                      "button",
                      {
                        key: f.name,
                        style: Object.assign({}, S.row, selected === f.name ? S.rowOn : null),
                        onClick: () => setSelected(f.name),
                        title: f.name
                      },
                      react.createElement("span", { style: { overflow: "hidden", textOverflow: "ellipsis" } }, f.name),
                      react.createElement("span", { style: S.dim }, Math.round(f.size / 1024) + "K")
                    ))
              )
            ),
            react.createElement(
              "div",
              { style: Object.assign({ flex: 1 }, S.card) },
              react.createElement("div", { style: S.cardHead }, "预览", selected ? " · " + selected : ""),
              react.createElement(
                "div",
                { style: S.preview },
                preview && preview.name === selected
                  ? react.createElement("img", { style: S.img, src: preview.url, alt: selected || "" })
                  : react.createElement("span", { style: S.dim }, selected ? "加载中…" : "选一个文件")
              )
            ),
            react.createElement(
              "div",
              { style: Object.assign({ width: "230px" }, S.card) },
              react.createElement("div", { style: S.cardHead }, "算子（默认参数）"),
              react.createElement(
                "div",
                { style: S.ops },
                ops.map((op) => react.createElement(
                  "button",
                  {
                    key: op.name,
                    style: S.op,
                    title: op.desc,
                    disabled: !selected || !!busy,
                    onClick: () => runOp(op)
                  },
                  busy === op.name ? op.name + "…" : op.name
                ))
              )
            )
          ),
          react.createElement("pre", { style: S.log }, log.length ? log.join("\n") : "操作日志会出现在这里，同时回显到当前会话。")
        );
      };
    }

    function apply(ctx) {
      const log = (m) => { try { console.error("[aseprite] " + m); } catch (e) {} };
      const PanelPage = makePanelPage(ctx);
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
        ctx.slots.inject("main", () => ctx.slots.register({ name: "main", key: PANEL_ID }, PanelPage));
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
