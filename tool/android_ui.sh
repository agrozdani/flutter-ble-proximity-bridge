#!/usr/bin/env bash
# Drives the app's UI on a connected Android device over adb, by the text
# Flutter exposes to accessibility (labels, tooltips, button text).
# See docs/device-testing.md.
#
#   tool/android_ui.sh texts                 List the labels on screen.
#   tool/android_ui.sh tap LABEL             Tap the element with that label.
#   tool/android_ui.sh wait LABEL [SECONDS]  Wait until a label shows up.
#   tool/android_ui.sh swipe X1 Y1 X2 Y2 [MS]
#   tool/android_ui.sh screenshot FILE.png
#   tool/android_ui.sh launch | stop
#
# Pick the device with ANDROID_SERIAL when more than one is attached.
# Labels are matched exactly against text=, content-desc= or hint= (a text
# field's placeholder), after unescaping the XML entities uiautomator writes
# (emoji, newlines).
set -euo pipefail

PACKAGE=com.example.ble_proximity_bridge
ADB=${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}

# uiautomator sometimes finds no window right after a screen change
# ("null root node returned"), so retry a few times.
dump() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$ADB" shell uiautomator dump /sdcard/window_dump.xml 2>&1 | grep -q "dumped to"; then
      "$ADB" exec-out cat /sdcard/window_dump.xml
      return
    fi
    sleep 0.5
  done
  echo "android_ui: uiautomator could not read the screen" >&2
  return 1
}

# One line per labelled node: "x1 y1 x2 y2<TAB>label".
nodes() {
  dump | python3 -c '
import sys, xml.etree.ElementTree as ET
for node in ET.parse(sys.stdin).iter("node"):
    bounds = node.get("bounds", "").replace("][", ",").strip("[]").split(",")
    for attr in ("text", "content-desc", "hint"):
        label = node.get(attr)
        if label and len(bounds) == 4:
            print(" ".join(bounds) + "\t" + label.replace("\n", "\\n"))
'
}

find_label() {
  nodes | WANT="$1" awk -F'\t' '$2 == ENVIRON["WANT"] { print $1; exit }'
}

cmd=${1:-}
shift || true
case "$cmd" in
  texts)
    nodes | cut -f2
    ;;
  tap)
    bounds=$(find_label "$1")
    if [[ -z "$bounds" ]]; then
      echo "android_ui: no element labelled \"$1\"" >&2
      exit 1
    fi
    read -r x1 y1 x2 y2 <<<"$bounds"
    "$ADB" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
    ;;
  wait)
    deadline=$((SECONDS + ${2:-10}))
    until [[ -n "$(find_label "$1")" ]]; do
      if ((SECONDS >= deadline)); then
        echo "android_ui: \"$1\" did not appear" >&2
        exit 1
      fi
      sleep 0.5
    done
    ;;
  swipe)
    "$ADB" shell input swipe "$@"
    ;;
  screenshot)
    "$ADB" exec-out screencap -p >"$1"
    ;;
  launch)
    "$ADB" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    ;;
  stop)
    "$ADB" shell am force-stop "$PACKAGE"
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
