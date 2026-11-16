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
# (emoji, newlines). Line breaks and tabs inside a label are written as \n
# and \t, by `texts` and in LABEL alike: pass a label exactly as `texts`
# prints it, in single quotes.
set -euo pipefail

PACKAGE=${ANDROID_UI_PACKAGE:-com.example.ble_proximity_bridge}
ADB=${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}

usage() {
  # The comment block above, without its leading "# ".
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit 64
}

# Stops with adb's own message when there is no device, more than one, or
# ANDROID_SERIAL names one that isn't attached.
require_device() {
  local state
  if ! state=$("$ADB" get-state 2>&1) || [[ $state != device ]]; then
    echo "android_ui: adb: $state" >&2
    exit 1
  fi
}

# uiautomator sometimes finds no window right after a screen change
# ("null root node returned"), so retry a few times.
dump() {
  local attempt output
  for attempt in 1 2 3 4 5; do
    output=$("$ADB" shell uiautomator dump /sdcard/window_dump.xml 2>&1) || true
    if [[ $output == *"dumped to"* ]]; then
      "$ADB" exec-out cat /sdcard/window_dump.xml
      return
    fi
    sleep 0.5
  done
  echo "android_ui: uiautomator could not read the screen: $output" >&2
  return 1
}

# One line per labelled node: "x1 y1 x2 y2<TAB>label". Fails, without
# output, when the screen could not be read.
nodes() {
  local xml
  xml=$(dump) || return 1
  python3 -c '
import sys, xml.etree.ElementTree as ET
for node in ET.fromstring(sys.stdin.read()).iter("node"):
    bounds = node.get("bounds", "").replace("][", ",").strip("[]").split(",")
    for attr in ("text", "content-desc", "hint"):
        label = node.get(attr)
        if label and len(bounds) == 4:
            label = label.replace("\n", "\\n").replace("\t", "\\t")
            print(" ".join(bounds) + "\t" + label)
' <<<"$xml"
}

# The bounds of the first node labelled $1; empty if there is none. Fails
# when the screen could not be read.
find_label() {
  local all
  all=$(nodes) || return 1
  WANT="$1" awk -F'\t' '!found && $2 == ENVIRON["WANT"] { print $1; found = 1 }' <<<"$all"
}

cmd=${1:-}
shift || true
case "$cmd" in
  texts | tap | wait | swipe | screenshot | launch | stop) require_device ;;
  *) usage ;;
esac

case "$cmd" in
  texts)
    all=$(nodes)
    cut -f2 <<<"$all"
    ;;
  tap)
    label=${1:?usage: tool/android_ui.sh tap LABEL}
    bounds=$(find_label "$label")
    if [[ -z "$bounds" ]]; then
      echo "android_ui: no element labelled \"$label\"" >&2
      exit 1
    fi
    read -r x1 y1 x2 y2 <<<"$bounds"
    "$ADB" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
    ;;
  wait)
    label=${1:?usage: tool/android_ui.sh wait LABEL [SECONDS]}
    deadline=$((SECONDS + ${2:-10}))
    while true; do
      bounds=$(find_label "$label")
      [[ -n "$bounds" ]] && break
      if ((SECONDS >= deadline)); then
        echo "android_ui: \"$label\" did not appear" >&2
        exit 1
      fi
      sleep 0.5
    done
    ;;
  swipe)
    (($# >= 4)) || { echo "usage: tool/android_ui.sh swipe X1 Y1 X2 Y2 [MS]" >&2; exit 64; }
    "$ADB" shell input swipe "$@"
    ;;
  screenshot)
    file=${1:?usage: tool/android_ui.sh screenshot FILE.png}
    "$ADB" exec-out screencap -p >"$file"
    ;;
  launch)
    # monkey reports a missing app on stdout and may still exit 0.
    output=$("$ADB" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>&1) || true
    if [[ $output != *"Events injected: 1"* ]]; then
      echo "android_ui: could not launch $PACKAGE:" >&2
      echo "$output" >&2
      exit 1
    fi
    ;;
  stop)
    "$ADB" shell am force-stop "$PACKAGE"
    ;;
esac
