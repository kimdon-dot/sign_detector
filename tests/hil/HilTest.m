classdef HilTest < matlab.unittest.TestCase
    % Raspberry Pi HIL 테스트
    %   runtests('HilTest', 'Tag', 'basic')   % Pi 설정을 안 바꾸는 테스트만
    %   runtests('HilTest')                    % 전부
    %
    % 구성: sign_detector.elf → can0 ═══ 선 ═══ can1 → candump. 시각은 모두 Pi 시계.
    % 배포는 DeployToPi가 먼저 해 둔다고 가정

    properties (Constant)
        ElfDir   = char(fileparts(hil_elf_path()));   % 프로젝트가 열려 있어야 함
        ModelDir = '/home/pi/sign_detector_project/best_ncnn_model';
    end

    methods (TestClassSetup)
        function checkPi(testCase)
            % ── 1. 접속 ──
            [status, out] = runOnPi('echo ok');
            testCase.assertEqual(status, 0, ['접속 실패: ' out]);

            % ── 2. 실행 파일 · 모델 폴더가 있는지 ──
            [status, ~] = runOnPi(['test -f ' HilTest.ElfDir '/sign_detector.elf']);
            testCase.assertEqual(status, 0, '.elf가 없음 (DeployToPi 먼저)');
            hidden = [HilTest.ModelDir '_hidden'];
            runOnPi(['test -d ' hidden ' && mv ' hidden ' ' HilTest.ModelDir]);   % 지난번 noModel 테스트가 숨긴 채 끝났으면 되돌리기
            [status, ~] = runOnPi(['test -d ' HilTest.ModelDir]);
            testCase.assertEqual(status, 0, '모델 폴더가 없음');

            % ── 3. can0, can1 올리기 ──
            for can = ["can0", "can1"]
                runOnPi("ip -br link show " + can + " | grep -q UP || " + canUpCmd(can));
                [~, out] = runOnPi("ip -br link show " + can);
                testCase.assertSubstring(out, 'UP', can + "이 UP이 아님 (CAN HAT 확인)");
            end
        end
    end

    methods (Test, TestTags = {'basic'})
        function normalOperation(testCase)
            % SWR-04 0.1초 주기 · SWR-11 ID/길이 · SWR-31 alive · SWR-34 상태
            testCase.addTeardown(@stopAll);
            startApp();
            pause(60);
            stopAll();
            f = readFrames("normal");

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
            testCase.addTeardown(@stopAll);
            startApp();
            pause(5);
            [~, out] = runOnPi('date +%s.%N && for i in 1 2 3 4; do nohup timeout 55 yes > /dev/null 2>&1 < /dev/null & done');
            loadStart = str2double(out);
            [~, out] = runOnPi('pgrep -c -x yes');
            testCase.verifyEqual(str2double(out), 4, 'CPU 부하(yes 4개)가 시작되지 않음');
            pause(55);
            [~, out] = runOnPi('date +%s.%N');
            loadEnd = str2double(out);
            stopAll();
            f = readFrames("load");

            inLoad = f.t >= loadStart & f.t <= loadEnd;
            gapMs = diff(f.t(inLoad)) * 1000;
            testCase.verifyGreaterThan(numel(gapMs), 400, '부하 구간 프레임이 너무 적음');
            testCase.verifyEqual(sum(abs(gapMs - 100) > 10), 0, '부하 중 간격이 100±10 ms를 벗어남 (SWR-04)');
            testCase.verifyTrue(all(mod(diff(f.alive), 256) == 1), '부하 중 alive 누락 (SWR-31)');
        end

        function processingRate(testCase)
            % SWR-21: 10초 평균 15 FPS 이상, 결과 간격 0.2초 이하
            % ncnn_infer.cpp가 5초마다 남기는 로그: "[ncnn_infer] fps 19.6 infer 47.3 ms max 101 ms n 98"
            testCase.addTeardown(@stopAll);
            startApp();
            pause(30);
            stopAll();
            [~, out] = runOnPi('grep -a ''ncnn_infer] fps'' /tmp/hil_app.log');
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
            % /tmp/stall_infer가 있는 동안 ncnn_infer.cpp가 결과를 안 냄
            testCase.addTeardown(@stopAll);
            startApp();
            pause(5);
            % 정지 훅은 DeployToPi로 배포한 빌드에만 있음 (-DNCNN_INFER_HIL)
            [status, ~] = runOnPi('grep -q ''HIL stall hook on'' /tmp/hil_app.log');
            testCase.assertEqual(status, 0, '인식 정지 훅이 없는 빌드 (DeployToPi로 다시 배포)');
            [~, out] = runOnPi('touch /tmp/stall_infer && date +%s.%N');
            stallStart = str2double(out);
            pause(4);
            [~, out] = runOnPi('rm -f /tmp/stall_infer && date +%s.%N');
            stallEnd = str2double(out);
            pause(11);
            stopAll();
            f = readFrames("stall");

            iLast  = find(f.t < stallEnd, 1, 'last');   % 멈추기 전 마지막 프레임
            iFirst = find(f.t > stallEnd, 1);           % 재개 후 첫 프레임
            stopDelay = f.t(iLast) - stallStart;
            % 하한 0.7: CAN 태스크가 보는 last_t는 정지 시작보다 0.05~0.2초 앞선 값
            % (추론 1회 + Rate Transition 전달 간격)이고 송신은 0.1초 단위라, 정상이어도 0.7~0.95초에 멈춤
            testCase.verifyGreaterThan(stopDelay, 0.7, '너무 일찍 송신이 멈춤 (SWR-32)');
            testCase.verifyLessThan(stopDelay, 1.15, '1초 뒤에 송신이 멈춰야 함 (SWR-32)');
            testCase.assertNotEmpty(iFirst, '인식이 돌아왔는데 송신이 재개되지 않음');
            testCase.verifyLessThan(f.t(iFirst) - stallEnd, 0.5, '0.5초 안에 재개되어야 함');
            testCase.verifyEqual(mod(f.alive(iFirst) - f.alive(iLast), 256), 1, '안 보낸 동안 alive가 늘어남 (SWR-31)');
        end

        function bootStatus(testCase)
            % SWR-34: 시작 직후부터 송신, 상태는 0(준비 중) → 1(정상)로만 바뀜
            testCase.addTeardown(@stopAll);
            t0 = startApp();
            pause(15);
            stopAll();
            f = readFrames("boot");

            testCase.assertNotEmpty(f.t, '시작 후 프레임이 없음');
            testCase.verifyLessThan(f.t(1) - t0, 2, '시작 후 2초 안에 송신해야 함');
            testCase.verifyTrue(all(diff(f.status) >= 0), '상태가 1에서 0으로 돌아감');
            testCase.verifyEqual(f.status(end), 1, '첫 인식 후 상태 1이어야 함 (SWR-34)');
        end
    end

    methods (Test, TestTags = {'fault'})
        function noModelStopsAfterBootTimeout(testCase)
            % SWR-34: 모델 파일을 못 읽으면 상태 0으로 보내다가 10초 뒤 멈춤
            hidden = [HilTest.ModelDir '_hidden'];
            runOnPi(['mv ' HilTest.ModelDir ' ' hidden]);                          % 모델 폴더 숨기기
            testCase.addTeardown(@() runOnPi(['mv ' hidden ' ' HilTest.ModelDir]));  % 끝나면 되돌리기
            testCase.addTeardown(@stopAll);
            t0 = startApp();
            pause(15);
            stopAll();
            f = readFrames("nomodel");

            testCase.assertNotEmpty(f.t, '모델이 없어도 처음에는 송신해야 함');
            testCase.verifyTrue(all(f.status == 0), '모델이 없으면 상태는 0이어야 함');
            % 10초는 첫 프레임부터 셈 (프로그램 시작 → 첫 프레임 약 1.2초는 빼고)
            testCase.verifyGreaterThan(f.t(end) - f.t(1), 9.7, '10초가 되기 전에 송신이 멈춤 (SWR-34)');
            testCase.verifyLessThan(f.t(end) - f.t(1), 10.2, '첫 프레임부터 10초 뒤 멈춰야 함');
            testCase.verifyLessThan(f.t(end) - t0, 13, '측정이 끝나기 전에 송신이 멈춰 있어야 함');
        end

        function canFailureKeepsRunning(testCase)
            % SWR-33: can0이 내려가도 프로그램은 계속 돌고, 다시 올라오면 0.5초 안에 재개
            % SWR-31: 못 보낸 동안에도 alive는 증가 → 재개 후 alive가 건너뜀
            testCase.addTeardown(@stopAll);
            testCase.addTeardown(@() runOnPi(canUpCmd("can0")));   % 중간에 실패해도 can0 되살리기
            startApp();
            pause(5);
            [~, out] = runOnPi('sudo ip link set can0 down && date +%s.%N');
            canDown = str2double(out);
            pause(5);
            [status, ~] = runOnPi('pgrep sign_detector');
            aliveWhileDown = (status == 0);
            [~, out] = runOnPi("date +%s.%N && " + canUpCmd("can0"));   % up 직전 시각
            canUp = str2double(out);
            pause(10);
            stopAll();
            f = readFrames("canfail");

            testCase.verifyTrue(aliveWhileDown, 'can0 down 중 프로그램이 죽음 (SWR-33)');
            testCase.verifyEqual(sum(f.t > canDown + 0.2 & f.t < canUp), 0, 'can0 down 동안 송신이 없어야 함');
            iFirst = find(f.t > canDown + 0.2, 1);   % 재개 후 첫 프레임
            testCase.assertNotEmpty(iFirst, 'can0 up 후 송신이 재개되지 않음 (SWR-33)');
            testCase.verifyLessThan(f.t(iFirst) - canUp, 0.5, 'can0 up 후 0.5초 안에 재개되어야 함 (SWR-33)');
            testCase.verifyGreaterThan(sum(f.t > canUp), 50, '재개 후 계속 송신해야 함');
            skipped = mod(f.alive(iFirst) - f.alive(iFirst - 1), 256) - 1;
            downCycles = (canUp - canDown) / 0.1;
            testCase.verifyGreaterThan(skipped, 0.8 * downCycles, '못 보낸 동안 alive가 늘어야 함 (SWR-31)');
        end
    end
end

% ───────────────────────── 도우미 함수 ─────────────────────────

function t0 = startApp()
    % 이전 실행 정리 → can1 기록 시작 → 프로그램 시작. t0 = 시작 직전 Pi 시각
    stopAll();
    runOnPi('rm -f /tmp/hil_can.log /tmp/hil_app.log');
    runOnPi('nohup stdbuf -oL candump -t a can1 > /tmp/hil_can.log 2>&1 < /dev/null &');
    % sudo: 생성 코드가 실시간 스케줄링을 씀
    % ';'로 나눔: 'A && B &'는 줄 전체가 백그라운드가 돼서 ssh가 안 돌아옴
    [~, out] = runOnPi(['date +%s.%N; cd ' HilTest.ElfDir '; ' ...
        'sudo nohup ./sign_detector.elf > /tmp/hil_app.log 2>&1 < /dev/null &']);
    t0 = str2double(out);
end

function stopAll()
    % 프로그램 · candump · CPU 부하 · 인식 정지 파일 정리
    % (프로세스 이름이 15자에서 잘려 'sign_detector.elf'로는 못 찾음)
    runOnPi('sudo pkill sign_detector; sleep 0.5; pkill candump; pkill -x yes; rm -f /tmp/stall_infer');
end

function cmd = canUpCmd(can)
    cmd = "sudo ip link set " + can + " up type can bitrate 500000 restart-ms 100";
end

function f = readFrames(name)
    % candump -t a 한 줄: " (1794208619.192621)  can1  100   [4]  00 00 2F 01"
    [status, out] = runOnPi('cat /tmp/hil_can.log');
    if status ~= 0
        error('candump 기록을 못 읽음: %s', out);   % 오류 문장을 프레임으로 읽지 않게
    end
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
    file = name + "_" + string(datetime('now', 'Format', 'yyyyMMdd_HHmmss')) + ".mat";
    save(fullfile(folder, file), 'f');
end
