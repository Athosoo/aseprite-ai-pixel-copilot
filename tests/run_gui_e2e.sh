#!/usr/bin/env bash
# GUI end-to-end test: real Aseprite + real extension code + real bridge + mock LLM
#
# Temporarily sets the preference scripts.show_run_script_alert=false (otherwise
# Aseprite pops a confirmation dialog and blocks), and restores it unconditionally
# afterwards. A brief Aseprite window appears while the test runs.
#
#   bash tests/run_gui_e2e.sh

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
BACKUP="/tmp/aseprite.ini.bak"
RESULT="$HERE/lua/gui_e2e_result.txt"
WATCHDOG=60

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  if [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$INI"
    echo "[runner] aseprite.ini restored"
  fi
}
trap cleanup EXIT

rm -f "$RESULT"

cp "$INI" "$BACKUP"
sed -i 's/^show_run_script_alert = true/show_run_script_alert = false/' "$INI"
echo "[runner] script-run confirmation temporarily disabled"

cd "$PROJ/bridge"
node test/mock_llm.mjs 8792 >/tmp/mock_llm.log 2>&1 &
PIDS+=($!)
sleep 1
node src/server.mjs --config test/gui-config.json >/tmp/bridge_gui.log 2>&1 &
PIDS+=($!)
sleep 1.5
echo "[runner] mock LLM + bridge up"

echo "[runner] launching GUI Aseprite probe (a window will flash) ..."
"$ASE" --script "$HERE/lua/gui_e2e_probe.lua" >/tmp/gui_e2e.log 2>&1 &
GUI_PID=$!
PIDS+=($GUI_PID)

for i in $(seq 1 $WATCHDOG); do
  if ! kill -0 "$GUI_PID" 2>/dev/null; then break; fi
  sleep 1
done
if kill -0 "$GUI_PID" 2>/dev/null; then
  echo "[runner] watchdog: GUI did not exit in ${WATCHDOG}s, killing it"
  kill -9 "$GUI_PID" 2>/dev/null || true
  sleep 1
fi

echo "================= RESULT ================="
cat "$RESULT" 2>/dev/null || echo "(no result file -- the probe never got that far)"
echo "================= bridge log ================="
tail -20 /tmp/bridge_gui.log 2>/dev/null
echo "================= mock llm log ================="
tail -5 /tmp/mock_llm.log 2>/dev/null
