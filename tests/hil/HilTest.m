classdef HilTest < matlab.unittest.TestCase
    % Raspberry Pi HIL 테스트
    %   runtests('HilTest', 'Tag', 'basic')   % Pi 설정을 안 바꾸는 테스트만
    %   runtests('HilTest')                    % 전부
    %
    % 구성: sign_detector.elf → can0 ═══ 선 ═══ can1 → candump. 시각은 모두 Pi 시계.
    % 배포는 DeployToPi가 먼저 해 둔다고 가정
    %
    % Pi에서 할 일(시나리오)은 hil.sh에 있고, 여기서는 판정만 함
    %   1. 시작할 때 hil.sh를 Pi의 ~/sign_detector_project/에 올림
    %   2. 테스트마다 시나리오 하나를 통째로 실행 (runPi)
    %   3. 출력된 "@이름 값" 줄과 can1 기록으로 판정

    methods (TestClassSetup)
        function preparePi(testCase)
            uploadScript();
            [ev, out] = runPi("prepare");   % 정리, can0 · can1 올리기, 실행 파일 · 모델 폴더 확인
            testCase.assertEqual(ev.elf,   1, ['.elf가 없음 (DeployToPi 먼저). ' out]);
            testCase.assertEqual(ev.model, 1, '모델 폴더가 없음');
            testCase.assertEqual(ev.can0,  1, 'can0이 UP이 아님 (CAN HAT 확인)');
            testCase.assertEqual(ev.can1,  1, 'can1이 UP이 아님 (CAN HAT 확인)');
        end
    end

    methods (Test, TestTags = {'basic'})
        function normalOperation(testCase)
            % SWR-04 0.1초 주기 · SWR-11 ID/길이 · SWR-31 alive · SWR-34 상태
            [~, out] = runPi("normal");   % 60초
            f = readFrames(out, "normal");

            testCase.assertGreaterThan(numel(f.t), 500, '60초 동안 프레임이 너무 적음');
            testCase.verifyEqual(unique(f.id), "100", 'CAN ID는 0x100 (SWR-11)');
            testCase.verifyEqual(unique(f.dlc), 4, '길이는 4 byte (SWR-11)');
            gapMs = diff(f.t) * 1000;
            testCase.verifyEqual(sum(abs(gapMs - 100) > 10), 0, '간격이 100±10 ms를 벗어남 (SWR-04)');
            testCase.verifyTrue(all(mod(diff(f.alive), 256) == 1), 'alive가 1씩 늘지 않음 (SWR-31)');
            testCase.verifyEqual(f.status(end), 1, '상태 1(정상)로 끝나야 함 (SWR-34)');
        end

        function periodUnderCpuLoad(testCase)
            % SWR-04: CPU 4코어를 다 써도 0.1초 주기 유지
            [ev, out] = runPi("cpu_load");   % 60초
            f = readFrames(out, "load");

            testCase.verifyEqual(ev.yesCount, 4, 'CPU 부하(yes 4개)가 시작되지 않음');
            inLoad = f.t >= ev.loadStart & f.t <= ev.loadEnd;
            gapMs = diff(f.t(inLoad)) * 1000;
            testCase.verifyGreaterThan(numel(gapMs), 400, '부하 구간 프레임이 너무 적음');
            testCase.verifyEqual(sum(abs(gapMs - 100) > 10), 0, '부하 중 간격이 100±10 ms를 벗어남 (SWR-04)');
            testCase.verifyTrue(all(mod(diff(f.alive), 256) == 1), '부하 중 alive 누락 (SWR-31)');
        end

        function processingRate(testCase)
            % SWR-21: 10초 평균 15 FPS 이상, 결과 간격 0.2초 이하
            [~, out] = runPi("processing_rate");   % 30초, FPS 로그 줄을 출력
            tok = regexp(out, 'fps ([\d.]+) infer [\d.]+ ms max ([\d.]+) ms', 'tokens');
            fps   = cellfun(@(c) str2double(c{1}), tok);
            maxMs = cellfun(@(c) str2double(c{2}), tok);

            testCase.assertGreaterThanOrEqual(numel(fps), 4, 'FPS 로그가 부족함');
            fps10 = (fps(1:end-1) + fps(2:end)) / 2;   % 5초 구간 2개 평균 = 10초 평균
            testCase.verifyGreaterThanOrEqual(min(fps10), 15, '10초 평균 FPS가 15보다 낮음 (SWR-21)');
            testCase.verifyLessThanOrEqual(max(maxMs), 200, '결과 간격이 0.2초를 넘음 (SWR-21)');
        end

        function stallStopsSending(testCase)
            % SWR-32: 인식이 1초 멈추면 송신 중지, 다시 인식하면 재개
            % SWR-31: 안 보낸 동안 alive는 그대로 → 재개 후 1만 증가
            [ev, out] = runPi("stall");   % 20초
            % 정지 훅은 DeployToPi로 배포한 빌드에만 있음 (-DNCNN_INFER_HIL)
            testCase.assertEqual(ev.hook, 1, '인식 정지 훅이 없는 빌드 (DeployToPi로 다시 배포)');
            f = readFrames(out, "stall");

            iLast  = find(f.t < ev.stallEnd, 1, 'last');   % 멈추기 전 마지막 프레임
            iFirst = find(f.t > ev.stallEnd, 1);           % 재개 후 첫 프레임
            stopDelay = f.t(iLast) - ev.stallStart;
            % 하한 0.7: CAN 태스크가 보는 last_t는 정지 시작보다 0.05~0.2초 앞선 값
            % (추론 1회 + Rate Transition 전달 간격)이고 송신은 0.1초 단위라, 정상이어도 0.7~0.95초에 멈춤
            testCase.verifyGreaterThan(stopDelay, 0.7, '너무 일찍 송신이 멈춤 (SWR-32)');
            testCase.verifyLessThan(stopDelay, 1.15, '1초 뒤에 송신이 멈춰야 함 (SWR-32)');
            testCase.assertNotEmpty(iFirst, '인식이 돌아왔는데 송신이 재개되지 않음');
            testCase.verifyLessThan(f.t(iFirst) - ev.stallEnd, 0.5, '0.5초 안에 재개되어야 함');
            testCase.verifyEqual(mod(f.alive(iFirst) - f.alive(iLast), 256), 1, '안 보낸 동안 alive가 늘어남 (SWR-31)');
        end

        function bootStatus(testCase)
            % SWR-34: 시작 직후부터 송신, 상태는 0(준비 중) → 1(정상)로만 바뀜
            [ev, out] = runPi("boot");   % 15초
            f = readFrames(out, "boot");

            testCase.assertNotEmpty(f.t, '시작 후 프레임이 없음');
            testCase.verifyLessThan(f.t(1) - ev.t0, 2, '시작 후 2초 안에 송신해야 함');
            testCase.verifyTrue(all(diff(f.status) >= 0), '상태가 1에서 0으로 돌아감');
            testCase.verifyEqual(f.status(end), 1, '첫 인식 후 상태 1이어야 함 (SWR-34)');
        end
    end

    methods (Test, TestTags = {'fault'})
        function noModelStopsAfterBootTimeout(testCase)
            % SWR-34: 모델 파일을 못 읽으면 상태 0으로 보내다가 10초 뒤 멈춤
            [ev, out] = runPi("no_model");   % 15초, 끝나면 모델 폴더를 되돌림
            f = readFrames(out, "nomodel");

            testCase.assertNotEmpty(f.t, '모델이 없어도 처음에는 송신해야 함');
            testCase.verifyTrue(all(f.status == 0), '모델이 없으면 상태는 0이어야 함');
            % 10초는 첫 프레임부터 셈 (프로그램 시작 → 첫 프레임 약 1.2초는 빼고)
            testCase.verifyGreaterThan(f.t(end) - f.t(1), 9.7, '10초가 되기 전에 송신이 멈춤 (SWR-34)');
            testCase.verifyLessThan(f.t(end) - f.t(1), 10.2, '첫 프레임부터 10초 뒤 멈춰야 함');
            testCase.verifyLessThan(f.t(end) - ev.t0, 13, '측정이 끝나기 전에 송신이 멈춰 있어야 함');
        end

        function canFailureKeepsRunning(testCase)
            % SWR-33: can0이 내려가도 프로그램은 계속 돌고, 다시 올라오면 0.5초 안에 재개
            % SWR-31: 못 보낸 동안에도 alive는 증가 → 재개 후 alive가 건너뜀
            [ev, out] = runPi("can_failure");   % 20초, 끝나면 can0을 되살림
            f = readFrames(out, "canfail");

            testCase.verifyEqual(ev.appAlive, 1, 'can0 down 중 프로그램이 죽음 (SWR-33)');
            testCase.verifyEqual(sum(f.t > ev.canDown + 0.2 & f.t < ev.canUp), 0, 'can0 down 동안 송신이 없어야 함');
            iFirst = find(f.t > ev.canDown + 0.2, 1);   % 재개 후 첫 프레임
            testCase.assertNotEmpty(iFirst, 'can0 up 후 송신이 재개되지 않음 (SWR-33)');
            testCase.verifyLessThan(f.t(iFirst) - ev.canUp, 0.5, 'can0 up 후 0.5초 안에 재개되어야 함 (SWR-33)');
            testCase.verifyGreaterThan(sum(f.t > ev.canUp), 50, '재개 후 계속 송신해야 함');
            skipped = mod(f.alive(iFirst) - f.alive(iFirst - 1), 256) - 1;
            downCycles = (ev.canUp - ev.canDown) / 0.1;
            testCase.verifyGreaterThan(skipped, 0.8 * downCycles, '못 보낸 동안 alive가 늘어야 함 (SWR-31)');
        end
    end
end

% ───────────────────────── 도우미 함수 ─────────────────────────
% PC에서 'ssh pi' · 'scp'가 비밀번호 없이 접속돼야 함

function uploadScript()
    % hil.sh → Pi (매번 올려서 PC 쪽 파일이 항상 원본)
    src = fullfile(fileparts(mfilename('fullpath')), 'hil.sh');
    piCommand("scp", """" + src + """ pi:sign_detector_project/hil.sh");
end

function [ev, out] = runPi(scenario)
    % Pi에서 hil.sh의 시나리오 하나 실행
    %   ev  : "@이름 값" 줄 → ev.이름 (숫자)
    %   out : 출력 전체 (can1 기록, FPS 로그 등)
    out = piCommand("ssh", "pi ""bash sign_detector_project/hil.sh " + scenario + """");
    ev = struct();
    for t = regexp(out, '^@(\w+) (\S+)', 'tokens', 'lineanchors')
        ev.(t{1}{1}) = str2double(t{1}{2});
    end
end

function out = piCommand(tool, args)
    % ssh / scp 실행. 접속 실패(255)면 3번까지 다시 시도, 그래도 실패하면 오류
    cmd = tool + " -o BatchMode=yes -o ConnectTimeout=5 " + args;
    for attempt = 1:3
        [status, out] = system(cmd);
        if status ~= 255, break; end
        pause(1);
    end
    if status ~= 0
        error('Pi 명령 실패 (종료 코드 %d): %s\n%s', status, cmd, strtrim(out));
    end
end

function f = readFrames(out, name)
    % hil.sh가 출력한 candump -t a 줄: " (1794208619.192621)  can1  100   [4]  00 00 2F 01"
    f.t = []; f.id = strings(0, 1); f.dlc = []; f.data = zeros(0, 4);
    for line = splitlines(string(out))'
        p = split(strtrim(line));
        if numel(p) < 4 || p(2) ~= "can1", continue; end   % CAN 프레임 줄만
        % 길이가 4 byte가 아닌 프레임도 읽음 (버리면 길이 검사가 못 잡음). 없는 byte는 NaN
        bytes = p(5:end);
        bytes = bytes(matches(bytes, regexpPattern('[0-9A-Fa-f]{2}')));
        n = min(numel(bytes), 4);
        row = nan(1, 4);
        if n > 0
            row(1:n) = hex2dec(bytes(1:n))';
        end
        f.t(end+1, 1)      = str2double(erase(p(1), ["(", ")"]));
        f.id(end+1, 1)     = p(3);
        f.dlc(end+1, 1)    = str2double(erase(p(4), ["[", "]"]));
        f.data(end+1, :)   = row;
    end
    f.speed    = f.data(:, 1);   % byte 1 제한속도
    f.detected = f.data(:, 2);   % byte 2 확정 여부
    f.alive    = f.data(:, 3);   % byte 3 alive counter
    f.status   = f.data(:, 4);   % byte 4 상태 (0 준비 중, 1 정상)

    % 측정 원본 남기기: tests/hil/results/<이름>_<시각>.mat
    folder = fullfile(fileparts(mfilename('fullpath')), 'results');
    if ~isfolder(folder), mkdir(folder); end
    file = name + "_" + string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + ".mat";
    save(fullfile(folder, file), 'f');
end
