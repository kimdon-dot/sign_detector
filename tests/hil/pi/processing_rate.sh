#!/bin/bash
# 30초 실행 뒤 FPS 로그 출력 (SWR-21)
# ncnn_infer.cpp가 5초마다 남기는 줄: "[ncnn_infer] fps 19.6 infer 47.3 ms max 101 ms n 98"
source "$(dirname "$0")/common.sh"
trap stop_all EXIT

start_app
sleep 30
stop_all

grep -a 'ncnn_infer] fps' "$APP_LOG" || true
