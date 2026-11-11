function r = hil_measure(scenario, duration, opts)
% hil_measure  Raspberry Pi 실기에서 CAN 송신을 기록하고 분석한다 (HIL 측정).
%
%   r = hil_measure("normal", 60)    % 정상 동작: 주기 · alive · 상태 (SWR-04, 11, 31)
%   r = hil_measure("load", 60)      % CPU 4코어 부하 중 주기 (SWR-04)
%   r = hil_measure("boot", 15)      % 시작 직후 상태 변화 (SWR-34)
%   r = hil_measure("nomodel", 15)   % 모델 파일 없음: 상태 0으로 10초 송신 후 중지 (SWR-34)  * Pi 설정을 잠깐 바꿈
%   r = hil_measure("stall", 20)     % 인식 4초 정지 → 1초 뒤 송신 중지, 다시 인식하면 재개 (SWR-32)
%   * 모든 시나리오에서 처리 속도(FPS, SWR-21)와 온도 · 클럭도 기록함
%   r = hil_measure("canfail", 20)   % 실행 중 can0 5초 down → 송신 중지, 프로그램 계속, up 후 재시작 없이 재개 (SWR-33)  * Pi 설정을 잠깐 바꿈
%
% 구성: can0(송신, 프로그램) ↔ can1(수신, candump). 두 채널이 선으로 연결되어 있어야 함 (SWR-35).
% 순서: can0/can1 올림 → 이전 프로그램 종료 → can1에서 candump 시작 → 프로그램 시작 → 시나리오 → 종료 → 분석
% 시각은 모두 Pi 시계 기준 (candump -t a 와 date +%s.%N)
% 결과: r 구조체, tests/hil/results/<scenario>_<시각>.mat (원본 로그 포함, 환경 변수 HIL_RESULT_DIR로 폴더 변경 가능)
%
% 주의: runModel은 예전 경로의 실행 파일을 띄우므로 쓰지 않는다. 배포 경로의 실행 파일을 sudo로 직접 실행한다
%       (생성 코드가 SCHED_FIFO를 쓰므로 root 필요).
arguments
    scenario (1, 1) string {mustBeMember(scenario, ["normal", "load", "boot", "nomodel", "canfail", "stall"])}
    duration (1, 1) double {mustBePositive} = 30
    opts.Elf (1, 1) string = "~/MATLAB_ws/R2026b/C/Users/don/Desktop/project/sign_detector/cache/sign_detector/sign_detector.elf"
    opts.ModelDir (1, 1) string = "~/sign_detector_project/best_ncnn_model"
    opts.Save (1, 1) logical = true
end

h = raspberrypi;
sh = @(cmd) system(h, char(cmd + "; true"));
[elfDir, elfName, elfExt] = fileparts(opts.Elf);
elfFile = elfName + elfExt;
% pkill/pgrep -f 패턴은 첫 글자를 [ ]로 감싸서, 그 명령을 실행하는 셸 자신은 잡히지 않게 함
elfPat = "'[" + extractBefore(elfFile, 2) + "]" + extractAfter(elfFile, 1) + "'";
candumpPat = "'[c]andump -t a can1'";
canLog = "/tmp/hil_can.log";
appLog = "/tmp/hil_app.log";

fprintf('[hil] %s, %g s\n', scenario, duration);
sh("for c in can0 can1; do ip -br link show $c | grep -q UP || sudo ip link set $c up type can bitrate 500000 restart-ms 100; done");
stopApp();
sh("pkill -f " + candumpPat + "; rm -f " + canLog + " " + appLog);
sh("(nohup stdbuf -oL candump -t a can1 > " + canLog + " 2>&1 &)");
throttledBefore = strtrim(sh("vcgencmd get_throttled"));
% pkill과 실행을 한 명령에 넣으면 pkill이 그 셸까지 잡으므로 따로 실행
sh("pkill -f '[h]il_thermal.sh'");
sh("printf '%s\n' 'while :; do echo $(date +%s.%N) $(vcgencmd measure_temp | tr -dc 0-9.) $(vcgencmd measure_clock arm | cut -d= -f2); sleep 1; done' > /tmp/hil_thermal.sh");
sh("(nohup sh /tmp/hil_thermal.sh > /tmp/hil_thermal.log 2>&1 &)");
pause(0.5);

% 끝나거나 중간에 오류가 나도 Pi를 원래대로 되돌림 (모델 폴더, can0, candump)
state = containers.Map({'restoreModel'}, {false});   % 핸들 객체: 정리 함수가 마지막 값을 읽음
cleanup = onCleanup(@() restorePi(sh, opts.ModelDir, state)); %#ok<NASGU>
events = struct('name', {}, 't', {});

if scenario == "nomodel"
    sh("mv " + opts.ModelDir + " " + opts.ModelDir + "_hidden");
    state('restoreModel') = true;
end

t0 = startApp();
mark("app start", t0);
switch scenario
    case {"normal", "boot", "nomodel"}
        pause(duration);
    case "load"
        pause(5);
        mark("load start", piTime());
        % 표준 출력과 오류를 모두 닫아야 ssh가 바로 돌아옴 (안 그러면 부하가 끝날 때까지 기다림)
        sh("for i in 1 2 3 4; do (nohup timeout " + (duration - 5) + " yes > /dev/null 2>&1 &); done");
        mark("busy loops: " + strtrim(sh("pgrep -c -x yes")), piTime());
        pause(duration - 5);
        mark("load end", piTime());
    case "canfail"
        pause(5);
        sh("sudo ip link set can0 down");
        mark("can0 down", piTime());   % 명령이 끝난 뒤 시각 (보내기 전 시각은 SSH 지연만큼 이름)
        pause(5);
        alive = strtrim(sh("pgrep -f " + elfPat + " | head -1"));
        mark("app alive while can0 down: " + string(~isempty(alive)), piTime());
        tUp0 = piTime();   % up 명령 직전 시각 (재개 시간의 기준)
        sh("sudo ip link set can0 up type can bitrate 500000 restart-ms 100");
        mark("can0 up", tUp0);
        pause(max(duration - 10, 5));   % 재시작하지 않고 재개되는지 봄 (SWR-33)
    case "stall"
        % 인식 정지 시험 훅(ncnn_infer.cpp): /tmp/stall_infer가 있는 동안 추론 결과가 나오지 않음
        % 시각은 같은 명령 안에서 파일을 만들거나 지운 직후에 찍음
        sh("rm -f /tmp/stall_infer");
        pause(5);
        mark("stall start", str2double(strtrim(sh("touch /tmp/stall_infer && date +%s.%N"))));
        pause(4);
        mark("stall end", str2double(strtrim(sh("rm -f /tmp/stall_infer && date +%s.%N"))));
        pause(max(duration - 9, 5));
end
stopApp();
pause(0.3);
sh("pkill -f " + candumpPat + "; pkill -f '[h]il_thermal.sh'");

raw = sh("cat " + canLog);
appText = sh("tail -40 " + appLog);
r = analyze(raw);
% 처리 속도 (SWR-21): ncnn_infer.cpp가 5초마다 남긴 "[ncnn_infer] fps F infer M ms max G ms n N"
% (G: 그 구간에서 연속한 두 결과 사이 최대 간격. 예전 실행 파일은 max가 없음 → NaN)
fpsTok = regexp(sh("grep -a 'ncnn_infer\] fps' " + appLog), 'fps ([\d.]+) infer ([\d.]+) ms(?: max ([\d.]+) ms)? n (\d+)', 'tokens');
r.fps = cellfun(@(c) str2double(c{1}), fpsTok(:));
r.inferMs = cellfun(@(c) str2double(c{2}), fpsTok(:));
r.gapMs = cellfun(@(c) str2double(c{3}), fpsTok(:));
% 발열: 1초마다 온도 [°C], ARM 클럭 [MHz]. throttled 값은 측정 전/후 (0x...0 이 아니면 그 순간 제한 중)
th = sscanf(sh("cat /tmp/hil_thermal.log"), '%f %f %f', [3 Inf])';
r.thermal = struct('t', th(:, 1), 'tempC', th(:, 2), 'armMHz', th(:, 3) / 1e6);
r.throttledBefore = throttledBefore;
r.throttledAfter = strtrim(sh("vcgencmd get_throttled"));
r.scenario = scenario;
r.duration = duration;
r.t0 = t0;
r.events = events;
r.appLog = appText;
r.raw = raw;
if ~isempty(r.t)
    r.firstFrameDelay = r.t(1) - t0;   % 프로그램 시작 → 첫 프레임 [s]
else
    r.firstFrameDelay = NaN;
end
report(r);
if opts.Save
    % 저장 폴더: 환경 변수 HIL_RESULT_DIR (Process Advisor의 RunHilTests가 PA_Results/hil로 지정), 없으면 tests/hil/results
    d = getenv('HIL_RESULT_DIR');
    if isempty(d), d = fullfile(fileparts(mfilename('fullpath')), 'results'); end
    if ~isfolder(d), mkdir(d); end
    f = fullfile(d, sprintf('%s_%s.mat', scenario, datestr(now, 'yyyymmdd_HHMMSS'))); %#ok<TNOW1,DATST>
    save(f, 'r');
    fprintf('[hil] 저장: %s\n', f);
    r.file = f;
end

    function t = startApp()
        t = piTime();
        sh("cd " + elfDir + " && (sudo nohup ./" + elfFile + " > " + appLog + " 2>&1 &)");
    end

    function stopApp()
        sh("sudo pkill -f " + elfPat + "; sleep 0.5");
    end

    function t = piTime()
        t = str2double(strtrim(sh("date +%s.%N")));
    end

    function mark(name, t)
        events(end + 1) = struct('name', char(name), 't', t);
        fprintf('[hil]   %-32s %.3f\n', name, t - t0);
    end

end

function restorePi(sh, modelDir, state)
if state('restoreModel')
    sh("[ -d " + modelDir + "_hidden ] && mv " + modelDir + "_hidden " + modelDir);
    fprintf('[hil] 모델 폴더 복구\n');
end
sh("sudo ip link set can0 up type can bitrate 500000 restart-ms 100 2>/dev/null; pkill -f '[c]andump -t a can1'; rm -f /tmp/stall_infer");
end

function r = analyze(raw)
% candump -t a 형식: " (1794208619.192621)  can1  100   [4]  00 00 2F 01"
lines = splitlines(string(raw));
tok = regexp(lines, '^\s*\((\d+\.\d+)\)\s+can1\s+([0-9A-Fa-f]+)\s+\[(\d)\]\s+((?:[0-9A-Fa-f]{2}\s*)*)$', 'tokens', 'once');
tok = tok(~cellfun(@isempty, tok));
n = numel(tok);
r.t = zeros(n, 1); r.id = strings(n, 1); r.dlc = zeros(n, 1); r.data = zeros(n, 4);
for i = 1:n
    r.t(i) = str2double(tok{i}{1});
    r.id(i) = upper(tok{i}{2});
    r.dlc(i) = str2double(tok{i}{3});
    b = sscanf(tok{i}{4}, '%x')';
    r.data(i, 1:numel(b)) = b;
end
r.n = n;
r.dt = diff(r.t) * 1000;                       % 송신 간격 [ms]
r.speed = r.data(:, 1); r.detected = r.data(:, 2); r.alive = r.data(:, 3); r.status = r.data(:, 4);
r.aliveGaps = sum(mod(diff(r.alive), 256) ~= 1);
r.outOfTol = sum(abs(r.dt - 100) > 10);
r.maxGap = max([r.dt; 0]);
end

function report(r)
fprintf('[hil] 프레임 %d개', r.n);
if r.n > 1
    fprintf(' · 간격 평균 %.1f ms (최소 %.1f, 최대 %.1f) · ±10 ms 초과 %d · alive 누락 %d', ...
        mean(r.dt), min(r.dt), max(r.dt), r.outOfTol, r.aliveGaps);
end
fprintf('\n');
if r.n > 0
    fprintf('[hil] 첫 프레임: 시작 후 %.2f s · ID %s · 길이 %s · 상태값 %s\n', r.firstFrameDelay, ...
        strjoin(unique(r.id), ','), mat2str(unique(r.dlc)'), mat2str(unique(r.status)'));
    i1 = find(r.status == 1, 1);
    if ~isempty(i1)
        fprintf('[hil] 상태 0 프레임 %d개, 상태 1 시작: 시작 후 %.2f s\n', i1 - 1, r.t(i1) - r.t0);
    end
end
if isfield(r, 'fps') && ~isempty(r.fps)
    fprintf('[hil] 처리 속도 %s FPS (5초 구간별) · 추론 1회 평균 %.1f ms · 결과 간격 최대 %.0f ms\n', ...
        mat2str(round(r.fps', 1)), mean(r.inferMs), max(r.gapMs));
end
if isfield(r, 'thermal') && ~isempty(r.thermal.t)
    fprintf('[hil] 온도 %.1f → %.1f °C (최고 %.1f) · ARM 클럭 최저 %.0f MHz · throttled %s → %s\n', ...
        r.thermal.tempC(1), r.thermal.tempC(end), max(r.thermal.tempC), min(r.thermal.armMHz), ...
        r.throttledBefore, r.throttledAfter);
end
end
