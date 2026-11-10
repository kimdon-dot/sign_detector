/* ncnn_infer: Pi에서 YOLO26n 추론을 NCNN C++ 라이브러리로 실행 (Python cam_sign_can.py와 같은 best_ncnn_model)
 * unit_recognize의 Infer/NCNN Infer 블록(MATLAB Function)이 시뮬레이션과 코드 생성 때 coder.ceval로 부름 */
#ifndef NCNN_INFER_H
#define NCNN_INFER_H

#ifdef __cplusplus
extern "C" {
#endif

/* rgb: 480x640x3 uint8, MATLAB 배열 순서(열 우선: 행 -> 열 -> 채널), R G B
 * y:   1x8x6300 single, MATLAB 배열 순서 (unit_recognize 안 Postprocess의 입력 형식)
 *      행 1~4: 박스 중심 x, 중심 y, 너비, 높이 [픽셀], 행 5~8: speed_30/60/90/120 점수 (sigmoid 후)
 * 반환: 0 성공, -1 모델 로드 실패, -2 추론 실패, -3 출력 크기가 다름,
 *       -4 인식 정지 시험 중 (Pi에서 /tmp/stall_infer 파일이 있을 때, HIL 전용) (실패하면 y는 0)
 * Pi에서는 5초마다 처리 속도를 표준 출력에 한 줄 남김: "[ncnn_infer] fps 19.60 infer 47.3 ms max 101 ms n 98" (SWR-21 HIL) */
int ncnn_infer(const unsigned char *rgb, float *y);

/* 모델 파일만 미리 읽음 (코어 지정 · 추론은 하지 않음). 반환: 0 성공, -1 로드 실패
 * Pi: 최상위 모델 sign_detector의 모델 초기화(Custom Code > Initialize function)에서 주기 태스크 시작 전에 부름.
 *     첫 추론에서 모델을 읽느라 송신 주기가 밀리던 문제(HIL: 시작 직후 간격 150~366 ms)를 없앰.
 *     부르지 않아도 ncnn_infer가 첫 호출에서 읽음 (PC 시뮬레이션) */
int ncnn_infer_preload(void);

#ifdef __cplusplus
}
#endif

#endif
