#!/bin/zsh
# shot.sh <udid> <set> <name> <wait> [launch args...]: relaunch the app on fakes with screenshot args, capture.
U=$1; S=$2; N=$3; W=$4; shift 4
OUT=${0:A:h}/../raw/$S; mkdir -p $OUT
xcrun simctl terminate $U me.somalabs.flight 2>/dev/null
xcrun simctl status_bar $U override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl launch $U me.somalabs.flight -useFakes YES "$@" >/dev/null
sleep $W
xcrun simctl io $U screenshot --type=png $OUT/$N.png >/dev/null 2>&1 && echo $OUT/$N.png
