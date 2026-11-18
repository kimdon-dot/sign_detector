#!/bin/bash
# 모델 폴더를 숨기고 15초 실행 (SWR-34)
source "$(dirname "$0")/common.sh"

mv "$MODEL_DIR" "${MODEL_DIR}_hidden"
trap 'stop_all; mv "${MODEL_DIR}_hidden" "$MODEL_DIR"' EXIT   # 끝나면 되돌리기

start_app
sleep 15
