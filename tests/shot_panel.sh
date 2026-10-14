#!/usr/bin/env bash
# 打开面板并截图，用于视觉检查（面板布局 / 中英文字体渲染）。
#
#   bash tests/shot_panel.sh [输出png]
#
# 会临时关闭脚本运行确认框，截图后杀掉该 Aseprite 实例并无条件还原首选项。

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
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
BACKUP="/tmp/aseprite.ini.bak"
OUT="${1:-$HERE/lua/panel_shot.png}"
READY="$HERE/lua/panel_shot_ready.txt"

ASE_PID=""
cleanup() {
  if [ -n "$ASE_PID" ]; then kill -9 "$ASE_PID" 2>/dev/null || true; fi
  if [ -f "$BACKUP" ]; then cp "$BACKUP" "$INI"; echo "[shot] aseprite.ini restored"; fi
}
trap cleanup EXIT

rm -f "$READY" "$OUT"

cp "$INI" "$BACKUP"
sed -i 's/^show_run_script_alert = true/show_run_script_alert = false/' "$INI"

echo "[shot] launching Aseprite with the panel probe ..."
"$ASE" --script "$HERE/lua/panel_shot_probe.lua" >/tmp/panel_shot.log 2>&1 &
ASE_PID=$!

# 等探针写出 ready
for _ in $(seq 1 30); do
  [ -f "$READY" ] && break
  sleep 0.5
done
if [ ! -f "$READY" ]; then
  echo "[shot] probe never signalled ready; log:"
  cat /tmp/panel_shot.log
  exit 1
fi
echo "[shot] probe ready: $(cat "$READY")"
sleep 1.5

powershell -NoProfile -ExecutionPolicy Bypass -File "$HERE/shot_window.ps1" -Out "$OUT" 2>&1 | tail -3
ls -la "$OUT" 2>&1
