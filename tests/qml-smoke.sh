#!/usr/bin/env bash
# Loads Model in the real Qt 6 QML engine and exercises its logic there.
# The QML engine parses less JavaScript than Node (no object spread, no async
# functions, no flatMap/at) — a parse error makes the plugin silently fail to
# load, and node --test stays green. This catches that. Run: bash tests/qml-smoke.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QML=""
for candidate in qml6 /usr/lib/qt6/bin/qml qml-qt6; do
  if command -v "$candidate" >/dev/null 2>&1; then QML="$candidate"; break; fi
done
if [[ -z $QML ]]; then
  echo "qml-smoke: no Qt 6 qml runtime found — install qt6-declarative" >&2
  exit 1
fi

out="$(QT_FORCE_STDERR_LOGGING=1 "$QML" -platform offscreen "$HERE/tests/qml/smoke.qml" 2>&1)"
status=$?
printf '%s\n' "$out"
if [[ $status -ne 0 || $out != *"SMOKE OK"* ]]; then
  echo "qml-smoke: FAIL (exit $status)" >&2
  exit 1
fi

# When the Quickshell modules are installed (a dev machine), also lint the
# plugin's own QML files; CI containers without Quickshell skip this half.
if [[ -d /usr/lib/qt6/qml/Quickshell ]] && command -v /usr/lib/qt6/bin/qmllint >/dev/null 2>&1; then
  if ! /usr/lib/qt6/bin/qmllint "$HERE"/*.qml; then
    echo "qml-smoke: qmllint FAIL" >&2
    exit 1
  fi
  echo "qml-smoke: qmllint ok"
fi

echo "qml-smoke: ok"
