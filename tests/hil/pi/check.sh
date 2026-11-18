#!/bin/bash
# 테스트 전 준비 · 확인 (HilTest의 TestClassSetup)
source "$(dirname "$0")/common.sh"

stop_all   # 지난번 실행이 남긴 프로세스 정리

# 지난번 no_model이 모델 폴더를 숨긴 채 끝났으면 되돌리기
[ -d "${MODEL_DIR}_hidden" ] && mv "${MODEL_DIR}_hidden" "$MODEL_DIR"

check elf   test -f "$ELF_DIR/sign_detector.elf"
check model test -d "$MODEL_DIR"

for can in can0 can1; do
    can_up $can
    check $can can_is_up $can
done
