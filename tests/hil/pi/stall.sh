#!/bin/bash
# 인식을 4초 멈췄다가 재개 (SWR-31 · 32)
# /tmp/stall_infer가 있는 동안 ncnn_infer.cpp가 결과를 안 냄 (DeployToPi 빌드에만 있는 훅)
source "$(dirname "$0")/common.sh"
trap stop_all EXIT

start_app
sleep 5

if ! grep -q 'HIL stall hook on' "$APP_LOG"; then
    mark hook 0   # 훅 없는 빌드면 더 할 게 없음
    exit 0
fi
mark hook 1

touch /tmp/stall_infer
mark stallStart
sleep 4

rm -f /tmp/stall_infer
mark stallEnd
sleep 11
