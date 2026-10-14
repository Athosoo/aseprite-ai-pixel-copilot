#!/usr/bin/env bash
# 真键盘验证：预填输入 -> 用 SendKeys 发真退格 -> 截图，看是不是真的删空了。
#
#   bash tests/run_key_test.sh [输出png]
#
# 不需要桥 / mock LLM：只开面板、预填、发键、截图。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
export ASE_PROJ="$PROJ"   # 探针靠它定位 extension/，不依赖 cwd
# Aseprite 可执行文件：优先 $ASE_BIN，其次 PATH 里的 aseprite，
# 最后回退到作者机器的常见位置（别人的机器请设 ASE_BIN）。
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
BACKUP="/tmp/aseprite.ini.keytest.bak"
OUT="${1:-$HERE/lua/gui_key_after.png}"

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null || true; done
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$INI"; echo "[keytest] aseprite.ini restored"; fi
}
trap cleanup EXIT

cp "$INI" "$BACKUP"
sed -i 's/^show_run_script_alert = true/show_run_script_alert = false/' "$INI"

python - "$INI" "$PROJ" <<'PYEOF'
import hashlib, io, re, sys
ini, proj = sys.argv[1], sys.argv[2]
mods = ["ws", "versions", "agent", "panel", "util", "ops", "i18n", "menu", "miniwindow", "settings"]
files = [f"{proj}/tests/lua/gui_key_probe.lua"]
for m in mods:
    files.append(f"{proj}/extension/lib/{m}.lua")
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
print(f"  已写入 {len(cands)} 条 script_access 授权")
PYEOF

echo "[keytest] launching Aseprite (a window will appear and take focus) ..."
"$ASE" --script "$HERE/lua/gui_key_probe.lua" >/tmp/gui_key.log 2>&1 &
PIDS+=($!)
sleep 12

echo "[keytest] 发 3 次真退格（会短暂抢前台）..."
powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/type_probe.ps1" \
    -Keys "{BACKSPACE}{BACKSPACE}{BACKSPACE}" 2>&1 | tee /tmp/kt_ps.log | tail -2

sleep 1.5
rm -f "$OUT"
powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "$OUT" 2>&1 | tail -1

echo "================= probe log ================="
tail -5 /tmp/gui_key.log 2>/dev/null
