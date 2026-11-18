#!/bin/bash
# CPU 4코어를 55초 동안 다 씀 (SWR-04)
source "$(dirname "$0")/common.sh"
trap stop_all EXIT

start_app
sleep 5

mark loadStart
for i in 1 2 3 4; do
    nohup timeout 55 yes > /dev/null 2>&1 < /dev/null &
done
sleep 0.5
mark yesCount "$(pgrep -c -x yes)"

sleep 54.5
mark loadEnd
