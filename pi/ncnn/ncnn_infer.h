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
 * 반환: 0 성공, -1 모델 로드 실패, -2 추론 실패, -3 출력 크기가 다름 (실패하면 y는 0) */
int ncnn_infer(const unsigned char *rgb, float *y);

#ifdef __cplusplus
}
#endif

#endif
