#!/usr/bin/env bash
# GUI 可视化验证：真 Aseprite + 真扩展代码 + 真桥 + mock LLM，最后截 Aseprite 窗口。
#
#   bash tests/run_gui_visual.sh [输出png]            # 老流程：面板端到端
#   bash tests/run_gui_visual.sh --menu [输出前缀]    # 新流程：命令表 + 贴边小面板，截两张
#
# 输出路径：从 PROJ/bridge 目录（脚本里会 cd 过去起桥）调用 powershell，
# 所以相对路径会解析到 bridge/ 下面 —— 传【绝对路径】最稳。
#
# 会临时改两处首选项（测完无条件还原）：
#   1) scripts.show_run_script_alert = false   否则运行脚本会弹确认框
#   2) [script_access] 预置授权                否则 io.open/WebSocket 会弹授权框阻塞
#      （键 = 脚本"源文件名"的 sha1，值 = 权限位掩码；等价于用户点一次"允许且不再提示"）
#      注意：每次都是【先删旧块再写新块】的幂等重建 —— 残留的半截授权会让整个测试被授权框挡住。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
ASE="D:/PraticleTool/Aseprite/aseprite.exe"
INI="$USERPROFILE/AppData/Roaming/Aseprite/aseprite.ini"
BACKUP="/tmp/aseprite.ini.visual.bak"

MODE="panel"
OUT="${1:-$HERE/lua/gui_panel.png}"
if [ "${1:-}" = "--menu" ]; then
  MODE="menu"
  OUT="${2:-$HERE/lua/gui_menu}"
elif [ "${1:-}" = "--term" ]; then
  MODE="menu"                       # 两张截图的流程一样，只是探针不同
  OUT="${2:-$HERE/lua/gui_term}"
fi

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$INI"; echo "[visual] aseprite.ini restored"; fi
}
trap cleanup EXIT

cp "$INI" "$BACKUP"

# --- 1) 关掉脚本运行确认框
sed -i 's/^show_run_script_alert = true/show_run_script_alert = false/' "$INI"

# --- 2) 预置 script_access 授权（含新增的 i18n / menu / miniwindow）
PROBE_LUA="gui_panel_probe.lua"
if [ "${1:-}" = "--menu" ]; then PROBE_LUA="gui_menu_probe.lua"; fi
if [ "${1:-}" = "--term" ]; then PROBE_LUA="gui_term_probe.lua"; fi
if [ "${1:-}" = "--term-en" ]; then MODE="menu"; OUT="${2:-$HERE/lua/gui_term_en}"; PROBE_LUA="gui_term_en_probe.lua"; fi

python - "$INI" "$PROJ" "$PROBE_LUA" <<'PYEOF'
import hashlib, io, re, sys
ini, proj, probe = sys.argv[1], sys.argv[2], sys.argv[3]
mods = ["ws", "versions", "agent", "panel", "util", "ops", "i18n", "menu", "miniwindow", "settings"]
files = [f"{proj}/tests/lua/{probe}"]
for m in mods:
    files.append(f"{proj}/extension/lib/{m}.lua")
# 两种分隔符都写上：--script 走 get_absolute_path（反斜杠），
# require 走 package.path 模板（正斜杠）。写错也无害。
cands = set()
for f in files:
    cands.add(f)
    cands.add(f.replace('/', chr(92)))
lines = ["[script_access]"]
for c in sorted(cands):
    key = hashlib.sha1(c.encode('utf-8')).hexdigest()
    lines.append(f"{key} = 31")   # Full = Execute|Write|Read|OpenSocket|LoadLib

s = io.open(ini, encoding='utf-8', errors='replace').read()
# 幂等：先删掉【本工具自己】追加过的旧块（到文件末尾为止），再追加新块。
# 不能"检测到块就跳过"——上一次跑残留的半截键会让本次全部弹授权框。
s = re.sub(r"\n?\[script_access\]\n(?:[0-9a-f]{40} = \d+\n?)*\Z", "", s)
if not s.endswith("\n"):
    s += "\n"
s += "\n".join(lines) + "\n"
io.open(ini, 'w', encoding='utf-8', newline='').write(s)
print(f"  已写入 {len(cands)} 条 script_access 授权（幂等重建）")
PYEOF

cd "$PROJ/bridge"
node test/mock_llm.mjs 8792 >/tmp/mock_llm.log 2>&1 &
PIDS+=($!)
sleep 1
node src/server.mjs --config test/gui-config.json >/tmp/bridge_visual.log 2>&1 &
PIDS+=($!)
sleep 1.5

echo "[visual] launching Aseprite (a window will appear) ..."
"$ASE" --script "$HERE/lua/$PROBE_LUA" >/tmp/gui_visual.log 2>&1 &
ASE_PID=$!
PIDS+=($ASE_PID)

if [ "$MODE" = "menu" ]; then
  # 第一张：命令表打开 + 悬浮高亮（探针 10s 后才切场景）
  sleep 8
  rm -f "${OUT}_menu.png"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "${OUT}_menu.png" 2>&1 | tail -1
  # 第二张：贴边小面板
  sleep 6
  rm -f "${OUT}_palette.png"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "${OUT}_palette.png" 2>&1 | tail -1
else
  sleep 10
  rm -f "$OUT"
  powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "$OUT" 2>&1 | tail -2
fi

echo "================= bridge log ================="
tail -8 /tmp/bridge_visual.log 2>/dev/null
echo "================= mock llm log ================="
tail -4 /tmp/mock_llm.log 2>/dev/null
