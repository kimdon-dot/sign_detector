#!/bin/bash
# HIL 시나리오 (Pi에서 실행). HilTest가 ~/sign_detector_project/hil.sh로 올리고 시나리오 이름으로 부름
#   bash ~/sign_detector_project/hil.sh stall      ← Pi에서 직접 돌려 봐도 됨
#
# 출력: 판정에 쓸 값은 "@이름 값" 한 줄 (mark), can1 기록은 candump 줄 그대로 (finish)
# 시각은 모두 Pi 시계 (date +%s.%N)
# 끝나면(중간에 끊겨도) restore가 프로그램을 멈추고 모델 폴더 · can0 · can1을 되돌림

MODEL_DIR=/home/pi/sign_detector_project/best_ncnn_model
APP_LOG=/tmp/hil_app.log   # 프로그램 출력 (FPS 로그 등)
CAN_LOG=/tmp/hil_can.log   # can1 수신 기록 (candump -t a)
# 실행 파일: 가장 최근에 빌드된 것 (= DeployToPi가 방금 배포한 것)
ELF=$(find ~/MATLAB_ws -name sign_detector.elf -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

# ───────────────────────── 공통 ─────────────────────────

mark() {   # mark 이름 [값]   값을 안 주면 지금 시각
    echo "@$1 ${2:-$(date +%s.%N)}"
}

check() {   # check 이름 명령...   명령이 성공하면 "@이름 1", 실패하면 "@이름 0"
    local name=$1; shift
    if "$@" > /dev/null 2>&1; then mark "$name" 1; else mark "$name" 0; fi
}

can_is_up() { ip -br link show "$1" | grep -q UP; }

can_up() {   # 이미 UP이면 그대로 둠
    can_is_up "$1" || sudo ip link set "$1" up type can bitrate 500000 restart-ms 100
}

stop_app() {
    # 프로그램 · candump · CPU 부하 · 인식 정지 파일 정리
    # (프로세스 이름이 15자에서 잘려 'sign_detector.elf'로는 못 찾음)
    sudo pkill sign_detector
    sleep 0.5
    pkill candump
    pkill -x yes
    rm -f /tmp/stall_infer
    return 0
}

restore() {   # 시나리오가 바꾼 Pi 상태 되돌리기
    stop_app
    [ -d "${MODEL_DIR}_hidden" ] && mv "${MODEL_DIR}_hidden" "$MODEL_DIR"
    can_up can0
    can_up can1
}

start_app() {   # can1 기록 시작 → 프로그램 시작. "@t0" = 시작 직전 시각
    stop_app
    rm -f "$CAN_LOG" "$APP_LOG"
    nohup stdbuf -oL candump -t a can1 > "$CAN_LOG" 2>&1 < /dev/null &
    mark t0
    # sudo: 생성 코드가 실시간 스케줄링을 씀
    (cd "$(dirname "$ELF")" && sudo nohup ./sign_detector.elf > "$APP_LOG" 2>&1 < /dev/null &)
}

finish() {   # 프로그램을 멈추고 can1 기록 출력 (HilTest가 프레임으로 읽음)
    stop_app
    cat "$CAN_LOG"
}

# ───────────────────────── 시나리오 ─────────────────────────

prepare() {   # 테스트 전 준비 · 확인
    restore   # 지난번 실행이 남긴 것 정리, 모델 폴더 · can0 · can1 되돌리기
    echo "실행 파일: ${ELF:-없음}"
    check elf   test -f "$ELF"
    check model test -d "$MODEL_DIR"
    check can0  can_is_up can0
    check can1  can_is_up can1
}

normal() {   # 정상 동작 60초 (SWR-04 · 11 · 31 · 34)
    start_app
    sleep 60
    finish
}

cpu_load() {   # CPU 4코어를 55초 동안 다 씀 (SWR-04)
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
    finish
}

processing_rate() {   # 30초 실행 뒤 FPS 로그 출력 (SWR-21)
    # ncnn_infer.cpp가 5초마다 남기는 줄: "[ncnn_infer] fps 19.6 infer 47.3 ms max 101 ms n 98"
    start_app
    sleep 30
    stop_app
    grep -a 'ncnn_infer] fps' "$APP_LOG" || true
}

stall() {   # 인식을 4초 멈췄다가 재개 (SWR-31 · 32)
    # /tmp/stall_infer가 있는 동안 ncnn_infer.cpp가 결과를 안 냄 (DeployToPi 빌드에만 있는 훅)
    start_app
    sleep 5
    if ! grep -q 'HIL stall hook on' "$APP_LOG"; then
        mark hook 0   # 훅 없는 빌드면 더 할 게 없음
        return
    fi
    mark hook 1
    touch /tmp/stall_infer
    mark stallStart
    sleep 4
    rm -f /tmp/stall_infer
    mark stallEnd
    sleep 11
    finish
}

boot() {   # 시작 직후 15초 (SWR-34)
    start_app
    sleep 15
    finish
}

no_model() {   # 모델 폴더를 숨기고 15초 실행 (SWR-34). 폴더는 restore가 되돌림
    mv "$MODEL_DIR" "${MODEL_DIR}_hidden"
    start_app
    sleep 15
    finish
}

can_failure() {   # can0을 5초 내렸다가 다시 올림 (SWR-31 · 33)
    start_app
    sleep 5
    sudo ip link set can0 down
    mark canDown
    sleep 5
    check appAlive pgrep sign_detector   # can0이 내려가도 프로그램이 살아 있는지
    mark canUp   # up 직전 시각
    can_up can0
    sleep 10
    finish
}

# ───────────────────────── 실행 ─────────────────────────

trap restore EXIT
"$1"
