/* ncnn_infer: YOLO26n을 NCNN으로 추론. unit_recognize의 Infer/NCNN Infer 블록이 coder.ceval로 부름 (PC · Pi 공통) */
#ifndef NCNN_INFER_H
#define NCNN_INFER_H

#ifdef __cplusplus
extern "C" {
#endif

/* rgb: 480x640x3 uint8 (MATLAB 열 우선, RGB)
 * y:   1x8x6300 single. 행 1~4: 박스 중심 x, y, 너비, 높이 [픽셀], 행 5~8: speed_30/60/90/120 점수
 * 반환: 0 성공, -1 모델 로드 실패, -2 추론 실패, -3 출력 크기 다름, -4 인식 정지 시험 중 (NCNN_INFER_HIL 빌드에서만),
 *       -5 카메라에서 새 영상이 안 옴 (Pi에서만). 실패하면 y는 0 */
int ncnn_infer(const unsigned char *rgb, float *y);

/* 모델 파일만 미리 읽음. 반환: 0 성공, -1 로드 실패
 * Pi: sign_detector의 Custom Code > Initialize function에서 부름 (첫 추론이 송신 주기를 밀지 않게).
 * 부르지 않으면 ncnn_infer가 첫 호출에서 읽음 (PC 시뮬레이션) */
int ncnn_infer_preload(void);

#ifdef __cplusplus
}
#endif

#endif
