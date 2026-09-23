#!/bin/sh
# A stand-in for `adb -s SERIAL ...`: an emulator in light mode at font scale 1.15
# that goes offline when asked to switch to dark mode.
shift 2
case "$*" in
  "shell cmd uimode night yes") echo "adb: device offline" >&2; exit 3 ;;
  "shell cmd uimode night") echo "Night mode: no" ;;
  "shell settings get system font_scale") echo "1.15" ;;
  "shell settings get global animator_duration_scale") echo "1.0" ;;
  "shell settings get global wifi_on") echo "1" ;;
esac
exit 0
