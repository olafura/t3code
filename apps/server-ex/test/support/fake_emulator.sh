#!/bin/sh
# A stand-in for the Android `emulator` binary with two AVDs.
if [ "$1" = "-list-avds" ]; then
  echo "Pixel_9"
  echo "Broken"
fi
