/* ncnn_infer: Pi에서 YOLO26n 추론을 NCNN C++ 라이브러리로 실행 (ncnn_infer.h 참고)
 * 모델: Pi의 Ultralytics NCNN 내보내기 (imgsz 480x640, end2end=False, 입력 in0, 출력 out0 = 8 x 6300)
 * 전처리는 Ultralytics와 같이 RGB, 0~1 (입력이 이미 640x480이라 letterbox 없음) */
#include "ncnn_infer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#ifdef __linux__
#include <sched.h>
#include <time.h>
#include <unistd.h>
#endif

/* /usr/local/include는 gcc 기본 경로 (빌드 정보에 -I/usr/local/include/ncnn을 넣으면 MATLAB이 원격 작업 폴더 경로로 바꿔 버림)
 * PC 시뮬레이션(Windows)은 unit_recognize 모델 설정 Simulation Target의 Include directories에서 찾음 */
#include <ncnn/cpu.h>
#include <ncnn/net.h>

/* 모델 폴더: 환경 변수 NCNN_INFER_MODEL_DIR가 있으면 그것을 씀 (PC 시뮬레이션: 프로젝트 시작 때 pi/ncnn/set_ncnn_model_dir.m이 설정)
 * 없으면 아래 값 (Pi) */
#ifndef NCNN_INFER_MODEL_DIR
#define NCNN_INFER_MODEL_DIR "/home/pi/sign_detector_project/best_ncnn_model"
#endif
/* NCNN이 쓰는 첫 코어. 0번 코어는 Simulink의 기본 주기 스레드와 CAN 송신 스레드에 남겨 둠
 * (최상위 모델 sign_detector에서 추론 주기 0.05초가 CAN 0.1초보다 우선순위가 높아서,
 *  같은 코어를 쓰면 추론이 계속 돌 때 CAN 송신이 밀림, SWR-23) */
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
/* HIL 측정용 (Pi에서만, 시뮬레이션에는 없음)
 * 1) 처리 속도 로그 (SWR-21): FPS_LOG_SEC마다 표준 출력에 한 줄
 *    "[ncnn_infer] fps 19.6 infer 47.3 ms n 98"  (n: 그 구간에 끝난 추론 수, infer: 추론 1회 평균 시간)
 * 2) 인식 정지 시험 훅 (SWR-32): STALL_FILE이 있는 동안 추론하지 않고 -4를 돌려줌 (결과 없음 = ok false)
 *    tests/hil/hil_measure.m의 "stall" 시나리오가 파일을 만들었다 지움. 파일이 없으면 동작에 영향 없음 */
#define FPS_LOG_SEC 5.0
#define STALL_FILE "/tmp/stall_infer"
static double mono_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
static double g_fps_t0 = 0.0;   /* 로그 구간 시작 시각 */
static double g_fps_busy = 0.0; /* 구간 동안 추론에 쓴 시간 합 */
static int g_fps_n = 0;         /* 구간 동안 끝난 추론 수 */
static void fps_tick(double t_start, double t_end)
{
    if (g_fps_t0 == 0.0) {
        g_fps_t0 = t_start;
    }
    g_fps_busy += t_end - t_start;
    g_fps_n++;
    const double span = t_end - g_fps_t0;
    if (span >= FPS_LOG_SEC) {
        (void)printf("[ncnn_infer] fps %.2f infer %.1f ms n %d\n", g_fps_n / span, 1000.0 * g_fps_busy / g_fps_n, g_fps_n);
        (void)fflush(stdout);
        g_fps_t0 = t_end;
        g_fps_busy = 0.0;
        g_fps_n = 0;
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
    (void)fflush(stdout);
    return 1;
}

/* 추론 스레드에서 첫 호출 때 한 번: 이 스레드를 코어 1~끝으로 옮김 */
static void pin_infer_thread(void)
{
#ifdef __linux__
    /* Simulink Linux 타깃 시작 코드가 프로세스를 코어 0에 고정하므로(MW_IS_CONCURRENT == 0),
     * NCNN(OpenMP) 스레드가 만들어지기 전에 이 스레드(추론 주기 스레드)를 코어 NCNN_INFER_FIRST_CPU~끝으로 옮김.
     * 나중에 만들어지는 OpenMP 스레드도 이 설정을 물려받고, NCNN에도 같은 코어를 알려 줌.
     * 다른 Simulink 스레드(기본 주기, CAN 송신)는 코어 0에 남음.
     * 그래서 이 부분은 ncnn_infer_preload(주 스레드, 태스크 생성 전)로 옮기면 안 됨: 이후 만들어지는 모든 스레드가 물려받음 */
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
    if (access(STALL_FILE, F_OK) == 0) {
        return -4;   /* 인식 정지 시험 (SWR-32 HIL): 결과 없음 */
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
