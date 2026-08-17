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
# plugin's own QML files; environments without Quickshell skip this half.
if [[ -d /usr/lib/qt6/qml/Quickshell ]] && command -v /usr/lib/qt6/bin/qmllint >/dev/null 2>&1; then
  # ---- the shell kit on the import path -------------------------------------
  #
  # The widget imports qs.Ui and qs.Commons — Omarchy's shell kit. qmllint finds
  # a module by looking for its directory under an import root, so `import qs.Ui`
  # needs a root holding `qs/Ui/qmldir`. Omarchy's `shell/` directory is that
  # tree one level down: it holds `Ui/` and `Commons/`, whose qmldir files
  # declare `module qs.Ui` and `module qs.Commons`. So the gate hands qmllint a
  # temporary root containing a single `qs` symlink pointing at the shell.
  #
  # Without it every qs.* type is unknown and qmllint checks nothing at all
  # about the kit — `Panel { moduelName: ... }` and `PanelActionButton { iconTxt:
  # ... }` both lint clean, because the types they sit on were never resolved.
  #
  # OMARCHY_QMLLINT_SHELL is the seam CI uses to point at a checkout; a dev
  # machine needs nothing. A machine with no Omarchy at all lints without the
  # kit rather than failing — the same lint this gate ran before.
  shell_dir=""
  for candidate in "${OMARCHY_QMLLINT_SHELL:-}" "${OMARCHY_PATH:+$OMARCHY_PATH/shell}" /usr/share/omarchy/shell; do
    if [[ -n $candidate && -d $candidate/Ui && -d $candidate/Commons ]]; then
      shell_dir="$candidate"
      break
    fi
  done

  lint_args=()
  if [[ -n $shell_dir ]]; then
    import_root="$(mktemp -d)"
    trap 'rm -rf "$import_root"' EXIT
    ln -s "$shell_dir" "$import_root/qs"
    lint_args=(-I "$import_root")
  fi

  lint_out="$(/usr/lib/qt6/bin/qmllint ${lint_args[@]+"${lint_args[@]}"} "$HERE"/*.qml 2>&1)"
  lint_status=$?
  printf '%s\n' "$lint_out"
  if [[ $lint_status -ne 0 ]]; then
    echo "qml-smoke: qmllint FAIL" >&2
    exit 1
  fi

  if [[ -n $shell_dir ]]; then
    # ---- names the kit does not have ----------------------------------------
    #
    # qmllint reports these as warnings and still exits 0, so the gate promotes
    # them itself. With the kit resolved they stop being environment noise and
    # start meaning "you wrote a name that is not there":
    #
    #   Could not find property "X".   — a property the type does not declare
    #   X was not found. …imports…     — a type the kit does not export
    #   … not found on type "T".       — a member the type does not have
    #
    # What this still does not catch, so nobody trusts it further than it goes:
    # `not found on type "QObject"` is excluded, because Style and Color hand out
    # their tokens as inline QtObject instances and qmllint reads the declared
    # type, not the instance — so every *correct* token (Style.font.family,
    # Color.menu.background) reports as missing. A typo inside those bags —
    # Style.font.headng — is indistinguishable from them and slips through; only
    # the live shell catches it. Unqualified access is left a warning for the
    # same reason: the kit's own components trip it.
    kit_misses="$(printf '%s\n' "$lint_out" \
      | grep -E 'Could not find property "|was not found\. Did you add all imports|not found on type "' \
      | grep -v 'not found on type "QObject"')"
    if [[ -n $kit_misses ]]; then
      echo "qml-smoke: qmllint FAIL — names the shell kit does not have:" >&2
      printf '%s\n' "$kit_misses" | sed 's/^/  /' >&2
      exit 1
    fi
    echo "qml-smoke: qmllint ok (kit resolved from $shell_dir)"
  else
    echo "qml-smoke: qmllint ok (no Omarchy shell found — kit names unchecked)"
  fi
fi

echo "qml-smoke: ok"
