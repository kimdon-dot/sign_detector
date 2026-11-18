#!/bin/bash
# can0을 5초 내렸다가 다시 올림 (SWR-31 · 33)
source "$(dirname "$0")/common.sh"
trap 'stop_all; can_up can0' EXIT   # 중간에 끊겨도 can0 되살리기

start_app
sleep 5

sudo ip link set can0 down
mark canDown
sleep 5

check appAlive pgrep sign_detector   # can0이 내려가도 프로그램이 살아 있는지

mark canUp   # up 직전 시각
can_up can0
sleep 10
