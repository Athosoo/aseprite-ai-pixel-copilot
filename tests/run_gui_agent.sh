#!/usr/bin/env bash
# 窗口尺寸行为探针（P4）：起真 GUI 跑 gui_agent_probe.lua，把 print 出来的数字打出来。
#
#   bash tests/run_gui_resize.sh
#
# 会临时改两处首选项（测完无条件还原）：
#   1) scripts.show_run_script_alert = false  否则运行脚本会弹确认框
#   2) [script_access] 预置授权               否则 WebSocket / io 会弹授权框
#
# Aseprite 可执行文件：优先 $ASE_BIN，其次 PATH 里的 aseprite，最后作者机器上的常见位置。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
export ASE_PROJ="$PROJ"

ASE="${ASE_BIN:-}"
if [ -z "$ASE" ]; then
  if command -v aseprite >/dev/null 2>&1; then
    ASE="aseprite"
  elif [ -x "D:/PraticleTool/Aseprite/aseprite.exe" ]; then
    ASE="D:/PraticleTool/Aseprite/aseprite.exe"
  else
    echo "找不到 Aseprite：请设 ASE_BIN=<aseprite.exe 的完整路径>" >&2
    exit 1
  fi
fi
INI="$USERPROFILE/AppData/Roaming/Aseprite/aseprite.ini"
BACKUP="/tmp/aseprite.ini.resize.bak"
LOG="/tmp/gui_agent.log"

# Aseprite 启动时会加载【已安装的扩展】，扩展的 main.lua 要读它目录里的
# __project.lua（install.ps1 写的仓库根路径）。那个读如果没在 script_access 里授权，
# Aseprite 一启动就弹原生的 Security 模态框，--script 的探针根本轮不到执行。
# 与其猜授权键，不如跑探针期间把扩展目录临时挪开，跑完原样挪回来。
# 注意：挪到 extensions/ 目录【里面】没用 —— Aseprite 是扫描整个目录来发现扩展的，
# 换个名字它照样当扩展加载（实测：挪成 ai-pixel-copilot.__probe_off 后仍然弹框）。
# 必须挪到 extensions/ 之外。
EXT_DIR="$USERPROFILE/AppData/Roaming/Aseprite/extensions"
EXT_INSTALLED="$EXT_DIR/ai-pixel-copilot"
EXT_PARKED="$USERPROFILE/AppData/Roaming/Aseprite/_extensions_parked_ai-pixel-copilot"

PIDS=()
restore_ext() {
  if [ -d "$EXT_PARKED" ]; then
    rm -rf "$EXT_INSTALLED" 2>/dev/null || true
    mv "$EXT_PARKED" "$EXT_INSTALLED" && echo "[agent] extension restored"
  fi
}
cleanup() {
  for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
  restore_ext
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$INI"; echo "[agent] aseprite.ini restored"; fi
}
trap cleanup EXIT

cp "$INI" "$BACKUP"
sed -i 's/^show_run_script_alert = true/show_run_script_alert = false/' "$INI"

PROBE_OUT="$PROJ/tests/lua/gui_agent_probe.out"
rm -f "$PROBE_OUT"
# GUI Aseprite 没有控制台，探针把结论写进这个文件（要 Windows 路径）
if command -v cygpath >/dev/null 2>&1; then
  export ASE_PROBE_OUT="$(cygpath -w "$PROBE_OUT")"
else
  export ASE_PROBE_OUT="$PROBE_OUT"
fi

# 授权要覆盖三类路径，漏一个就会被模态的 Security 框卡住：
#   1) 探针脚本自己（执行）
#   2) 探针要写的输出文件（写）
#   3) 【已安装的扩展】的所有文件 —— Aseprite 启动时会加载扩展的 main.lua，
#      它会读扩展目录里的 __project.lua（install.ps1 写的仓库根路径），
#      那个读如果没授权，启动阶段就弹框，--script 的探针根本轮不到执行。
python - "$INI" "$PROJ" "$ASE_PROBE_OUT" <<'PYEOF'
import hashlib, io, os, re, sys
ini, proj, probe_out = sys.argv[1], sys.argv[2], sys.argv[3]
ext_installed = os.path.join(os.environ.get('APPDATA', ''), 'Aseprite', 'extensions', 'ai-pixel-copilot')

mods = ["ws", "versions", "agent", "panel", "util", "ops", "i18n", "menu", "miniwindow", "settings"]
files = [f"{proj}/tests/lua/gui_agent_probe.lua", probe_out]
for m in mods:
    files.append(f"{proj}/extension/lib/{m}.lua")
for root, _dirs, names in os.walk(ext_installed):
    for n in names:
        files.append(os.path.join(root, n).replace(os.sep, '/'))

cands = set()
for f in files:
    cands.add(f)
    cands.add(f.replace('/', chr(92)))
lines = ["[script_access]"]
for c in sorted(cands):
    lines.append(f"{hashlib.sha1(c.encode('utf-8')).hexdigest()} = 31")
s = io.open(ini, encoding='utf-8', errors='replace').read()
s = re.sub(r"\n?\[script_access\]\n(?:[0-9a-f]{40} = \d+\n?)*\Z", "", s)
if not s.endswith("\n"):
    s += "\n"
s += "\n".join(lines) + "\n"
io.open(ini, 'w', encoding='utf-8', newline='').write(s)
print(f"  已写入 {len(cands)} 条 script_access 授权（幂等重建）")
PYEOF

if [ -d "$EXT_INSTALLED" ]; then
  mv "$EXT_INSTALLED" "$EXT_PARKED" && echo "[agent] extension temporarily parked"
fi

echo "[agent] launching Aseprite (a window will appear) ..."
"$ASE" --script "$HERE/lua/gui_agent_probe.lua" >"$LOG" 2>&1 &
PIDS+=($!)

# 探针跑得很快（1 秒内出结论），但会停在底边栏等 8 秒再关窗 —— 先截图，再收结论
sleep 4
rm -f "$PROJ/tests/lua/gui_agent_shot.png"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "$PROJ/tests/lua/gui_agent_shot.png" 2>&1 | tail -1

for _ in $(seq 1 20); do
  sleep 0.5
  if grep -q "PROBE EXIT" "$PROBE_OUT" 2>/dev/null; then break; fi
done

echo "================= probe output ================="
cat "$PROBE_OUT" 2>/dev/null || echo "(探针没写出任何东西)"
echo "================= stdout/stderr ================="
cat "$LOG"
