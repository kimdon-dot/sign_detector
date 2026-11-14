/* ncnn_infer: YOLO26n을 NCNN으로 추론 (ncnn_infer.h 참고)
 * 모델: Ultralytics NCNN 내보내기 (480x640, 입력 in0, 출력 out0 = 8 x 6300). 전처리: RGB 0~1, letterbox 없음 */
#include "ncnn_infer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>
#ifdef __linux__
#include <sched.h>
#include <time.h>
#include <unistd.h>
#endif

/* Pi: /usr/local/include (gcc 기본 경로. -I로 넣으면 MATLAB이 원격 폴더 경로로 바꿔 버림)
 * PC: unit_recognize의 Simulation Target > Include directories */
#include <ncnn/cpu.h>
#include <ncnn/net.h>

/* 모델 폴더: 환경 변수 NCNN_INFER_MODEL_DIR (PC: set_ncnn_model_dir.m이 설정), 없으면 아래 값 (Pi) */
#ifndef NCNN_INFER_MODEL_DIR
#define NCNN_INFER_MODEL_DIR "/home/pi/sign_detector_project/best_ncnn_model"
#endif
/* NCNN이 쓰는 첫 코어. 코어 0은 기본 주기 · CAN 송신 스레드용
 * (추론 주기가 CAN보다 우선순위가 높아 같은 코어면 CAN 송신이 밀림, SWR-04) */
#ifndef NCNN_INFER_FIRST_CPU
#define NCNN_INFER_FIRST_CPU 1
#endif

static const int H = 480;
static const int W = 640;
static const int ROWS = 8;
static const int ANCHORS = 6300; /* 80x60 + 40x30 + 20x15 */

static ncnn::Net *g_net = nullptr;
static int g_state = 0;    /* 모델 파일: 0 읽기 전, 1 읽음, -1 읽기 실패 */
static int g_threads = 1;  /* 추론 스레드 수 */
static int g_pinned = 0;   /* 추론 스레드 코어 지정을 했는지 */

#ifdef __linux__
/* HIL용 (Pi에서만)
 * 1) 처리 속도 로그 (SWR-21): 5초마다 "[ncnn_infer] fps 19.6 infer 47.3 ms max 101 ms n 98"
 *    (infer: 추론 1회 평균, max: 연속한 두 결과 사이 최대 간격, n: 추론 수)
 * 2) 인식 정지 시험 (SWR-32): STALL_FILE이 있는 동안 -4 (결과 없음). HilTest의 stallStopsSending이 씀
 *    NCNN_INFER_HIL을 정의한 빌드에만 들어감 (DeployToPi → pi_postcodegen이 -DNCNN_INFER_HIL을 붙임).
 *    /tmp는 누구나 쓸 수 있어서, 일반 빌드에 넣으면 파일 하나로 인식을 멈출 수 있음 */
#define FPS_LOG_SEC 5.0
#ifdef NCNN_INFER_HIL
#define STALL_FILE "/tmp/stall_infer"
#endif
static double mono_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
/* 카메라 정지 감지 (Pi에서만. PC 테스트는 같은 사진을 계속 넣으므로 쓰지 않음)
 * Pi 카메라 블록은 새 프레임이 없으면 직전 프레임을 그대로 돌려주고 상태 출력도 없어서, 카메라가 멈추면
 * 멈춘 영상으로 추론이 계속 성공함. 직전과 완전히 같은 영상이 STALE_FRAMES번 이어지면 결과 없음(-5)으로 처리
 * → ok = 0 → 1초 이어지면 인식 정지 (SWR-32). 추론이 카메라보다 빨라 어쩌다 같은 프레임을 한 번 더 읽는 것은 그대로 추론 */
#define STALE_FRAMES 3
static std::vector<unsigned char> g_prev_rgb; /* 직전 호출의 영상 */
static int g_same_n = 0;                      /* 직전과 같은 영상이 이어진 횟수 */
static int same_frame_count(const unsigned char *rgb)
{
    const size_t n = (size_t)H * W * 3;
    if (g_prev_rgb.size() == n && memcmp(g_prev_rgb.data(), rgb, n) == 0) {
        if (g_same_n < STALE_FRAMES) {
            g_same_n++;
        }
    } else {
        g_prev_rgb.assign(rgb, rgb + n);
        g_same_n = 0;
    }
    return g_same_n;
}
static double g_fps_t0 = 0.0;   /* 로그 구간 시작 시각 */
static double g_fps_busy = 0.0; /* 구간 동안 추론에 쓴 시간 합 */
static int g_fps_n = 0;         /* 구간 동안 끝난 추론 수 */
static double g_prev_end = 0.0; /* 직전 추론이 끝난 시각 (0: 아직 없음) */
static double g_gap_max = 0.0;  /* 구간 동안 연속한 두 결과 사이 최대 간격 */
static void fps_tick(double t_start, double t_end)
{
    if (g_fps_t0 == 0.0) {
        g_fps_t0 = t_start;
    }
    if (g_prev_end > 0.0 && t_end - g_prev_end > g_gap_max) {
        g_gap_max = t_end - g_prev_end;
    }
    g_prev_end = t_end;
    g_fps_busy += t_end - t_start;
    g_fps_n++;
    const double span = t_end - g_fps_t0;
    if (span >= FPS_LOG_SEC) {
        (void)printf("[ncnn_infer] fps %.2f infer %.1f ms max %.0f ms n %d\n", g_fps_n / span, 1000.0 * g_fps_busy / g_fps_n,
                     1000.0 * g_gap_max, g_fps_n);
        (void)fflush(stdout);
        g_fps_t0 = t_end;
        g_fps_busy = 0.0;
        g_fps_n = 0;
        g_gap_max = 0.0;
    }
}
#endif

/* NCNN이 쓸 코어 범위와 스레드 수 (코어는 바꾸지 않음) */
static void cpu_range(long *first, long *ncpu, int *threads)
{
#ifdef __linux__
    *ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    *first = (*ncpu > NCNN_INFER_FIRST_CPU) ? NCNN_INFER_FIRST_CPU : 0;
    *threads = (int)(*ncpu - *first);
#else
    /* PC 시뮬레이션: 코어 고정 없이 NCNN 기본 스레드 수 */
    *first = 0;
    *ncpu = ncnn::get_cpu_count();
    *threads = ncnn::get_physical_big_cpu_count();
#endif
}

/* 모델 파일 읽기. 어느 스레드에서 불러도 됨 (코어 지정 · OpenMP 스레드 생성 없음) */
static int load_files(void)
{
    long first, ncpu;
    cpu_range(&first, &ncpu, &g_threads);
    const char *env = getenv("NCNN_INFER_MODEL_DIR");
    const std::string dir = (env && env[0]) ? env : NCNN_INFER_MODEL_DIR;
    g_net = new ncnn::Net();
    g_net->opt.use_vulkan_compute = false;
    g_net->opt.num_threads = g_threads;
    if (g_net->load_param((dir + "/model.ncnn.param").c_str()) != 0 ||
        g_net->load_model((dir + "/model.ncnn.bin").c_str()) != 0) {
        (void)fprintf(stderr, "[ncnn_infer] model load failed: %s\n", dir.c_str());
        (void)fflush(stderr);
        return -1;
    }
    (void)printf("[ncnn_infer] model %s, %d threads on cpu %ld-%ld (of %ld)\n", dir.c_str(), g_threads, first, ncpu - 1, ncpu);
#if defined(__linux__) && defined(NCNN_INFER_HIL)
    (void)printf("[ncnn_infer] HIL stall hook on (%s)\n", STALL_FILE);   /* HilTest가 이 줄로 훅이 있는 빌드인지 확인 */
#endif
    (void)fflush(stdout);
    return 1;
}

/* 추론 스레드에서 첫 호출 때 한 번: 이 스레드를 코어 1~끝으로 옮김 */
static void pin_infer_thread(void)
{
#ifdef __linux__
    /* Simulink 시작 코드가 프로세스를 코어 0에 고정하므로, OpenMP 스레드가 생기기 전에 이 스레드를 옮김
     * (이후 OpenMP 스레드가 물려받음). 다른 Simulink 스레드는 코어 0에 남음.
     * ncnn_infer_preload(주 스레드)로 옮기면 안 됨: 그 뒤 생기는 모든 스레드가 물려받음 */
    long first, ncpu;
    int threads;
    cpu_range(&first, &ncpu, &threads);
    cpu_set_t cpus;
    CPU_ZERO(&cpus);
    ncnn::CpuSet mask;
    for (long i = first; i < ncpu; i++) {
        CPU_SET(i, &cpus);
        mask.enable((int)i);
    }
    if (sched_setaffinity(0, sizeof(cpus), &cpus) != 0) {
        perror("[ncnn_infer] sched_setaffinity");
    }
    /* set_cpu_powersave(0)은 모든 코어로 되돌리므로 쓰지 않고, 코어를 직접 지정 */
    if (ncnn::set_cpu_thread_affinity(mask) != 0) {
        (void)fprintf(stderr, "[ncnn_infer] set_cpu_thread_affinity failed\n");
    }
#endif
}

int ncnn_infer_preload(void)
{
    if (g_state == 0) {
        g_state = load_files();
    }
    return (g_state > 0) ? 0 : -1;
}

int ncnn_infer(const unsigned char *rgb, float *y)
{
    memset(y, 0, sizeof(float) * ROWS * ANCHORS);
    if (!g_pinned) {
        pin_infer_thread();
        g_pinned = 1;
    }
    if (g_state == 0) {
        g_state = load_files();   /* 미리 읽지 않았으면 여기서 (PC 시뮬레이션) */
    }
    if (g_state < 0) {
        return -1;
    }
#ifdef __linux__
#ifdef NCNN_INFER_HIL
    if (access(STALL_FILE, F_OK) == 0) {
        return -4;   /* 인식 정지 시험 */
    }
#endif
    if (same_frame_count(rgb) >= STALE_FRAMES) {
        return -5;   /* 카메라에서 새 영상이 안 옴 */
    }
    const double t_start = mono_now();
#endif

    /* MATLAB 열 우선 rgb[r + H*c + H*W*ch] -> NCNN 채널 평면 in.channel(ch).row(r)[c], /255 */
    ncnn::Mat in(W, H, 3);
    const float s = 1.0f / 255.0f;
    for (int ch = 0; ch < 3; ch++) {
        float *plane = in.channel(ch);
        const unsigned char *src = rgb + (size_t)H * W * ch;
        for (int c = 0; c < W; c++) {
            const unsigned char *col = src + (size_t)H * c;
            for (int r = 0; r < H; r++) {
                plane[(size_t)r * W + c] = static_cast<float>(col[r]) * s;
            }
        }
    }

    ncnn::Extractor ex = g_net->create_extractor();
    ex.input("in0", in);
    ncnn::Mat out;
    if (ex.extract("out0", out) != 0) {
        return -2;
    }
    if (out.w != ANCHORS || out.h != ROWS) {
        static int warned = 0;
        if (!warned) {
            (void)fprintf(stderr, "[ncnn_infer] unexpected output %dx%dx%d (want w=%d h=%d)\n", out.w, out.h, out.c, ANCHORS, ROWS);
            (void)fflush(stderr);
            warned = 1;
        }
        return -3;
    }
    /* NCNN out.row(k)[a] -> MATLAB y(1, k+1, a+1) = y[k + ROWS*a] */
    for (int k = 0; k < ROWS; k++) {
        const float *row = out.row(k);
        for (int a = 0; a < ANCHORS; a++) {
            y[k + ROWS * a] = row[a];
        }
    }
#ifdef __linux__
    fps_tick(t_start, mono_now());
#endif
    return 0;
}
