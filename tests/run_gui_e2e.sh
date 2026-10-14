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
ASE="D:/PraticleTool/Aseprite/aseprite.exe"
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
