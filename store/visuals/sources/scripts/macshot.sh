#!/bin/zsh
# macshot.sh <name> <wait> [launch args...]: relaunch the Debug Mac app on fakes, capture its main window (no shadow).
N=$1; W=$2; shift 2
APP=/private/tmp/claude-501/dd-flight-visuals/Build/Products/Debug/SomaFlight.app
OUT=${0:A:h}/../raw/mac; mkdir -p $OUT
pkill -f "$APP/Contents/MacOS/SomaFlight"; sleep 2
open -n $APP --args -useFakes YES "$@"; sleep $W; open $APP; sleep 3
ID=$(swift ${0:A:h}/wins.swift | awk '/Soma Flight Soma Flight/{print $1; exit}')
screencapture -x -o -l $ID $OUT/$N.png && echo $OUT/$N.png
