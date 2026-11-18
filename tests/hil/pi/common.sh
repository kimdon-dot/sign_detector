# HIL 시나리오 공통 함수 (시나리오 스크립트가 맨 앞에서 source 함)
#
# MATLAB에 값 넘기기: "@이름 값" 한 줄 (mark). runPiScript가 이 줄을 읽어 ev.이름으로 돌려줌
# 시각은 모두 Pi 시계 (date +%s.%N)

HIL_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
source "$HIL_DIR/env.sh"   # ELF_DIR: 실행 파일 폴더 (PC 쪽 경로에 따라 달라서 HilTest가 만들어 올림)

MODEL_DIR=/home/pi/sign_detector_project/best_ncnn_model
APP_LOG=/tmp/hil_app.log   # 프로그램 출력 (FPS 로그 등)
CAN_LOG=/tmp/hil_can.log   # can1 수신 기록 (candump -t a)

mark() {   # mark 이름 [값]   값을 안 주면 지금 시각
    echo "@$1 ${2:-$(date +%s.%N)}"
}

check() {   # check 이름 명령...   명령이 성공하면 "@이름 1", 실패하면 "@이름 0"
    local name=$1; shift
    if "$@" > /dev/null 2>&1; then mark "$name" 1; else mark "$name" 0; fi
}

can_is_up() {
    ip -br link show "$1" | grep -q UP
}

can_up() {   # 이미 UP이면 그대로 둠
    can_is_up "$1" || sudo ip link set "$1" up type can bitrate 500000 restart-ms 100
}

stop_all() {
    # 프로그램 · candump · CPU 부하 · 인식 정지 파일 정리
    # (프로세스 이름이 15자에서 잘려 'sign_detector.elf'로는 못 찾음)
    sudo pkill sign_detector
    sleep 0.5
    pkill candump
    pkill -x yes
    rm -f /tmp/stall_infer
    return 0
}

start_app() {
    # 이전 실행 정리 → can1 기록 시작 → 프로그램 시작. "@t0" = 시작 직전 시각
    stop_all
    rm -f "$CAN_LOG" "$APP_LOG"
    nohup stdbuf -oL candump -t a can1 > "$CAN_LOG" 2>&1 < /dev/null &
    mark t0
    # sudo: 생성 코드가 실시간 스케줄링을 씀
    (cd "$ELF_DIR" && sudo nohup ./sign_detector.elf > "$APP_LOG" 2>&1 < /dev/null &)
}
