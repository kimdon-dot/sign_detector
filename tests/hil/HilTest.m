classdef HilTest < matlab.unittest.TestCase
    % HilTest  Raspberry Pi 실기 HIL 테스트 (요구사항별 판정)
    %
    %   results = runtests('HilTest', 'Tag', 'basic');   % Pi 설정을 바꾸지 않는 시나리오만
    %   results = runtests('HilTest');                    % 전부 (nomodel, canfail은 Pi 설정을 잠깐 바꿨다 되돌림)
    %
    % 각 테스트는 hil_measure로 실제로 측정한 뒤 판정한다. 측정 결과는 tests/hil/results/에 남는다.
    % 테스트 메서드를 Requirements Toolbox로 해당 SWR에 Verify 링크하면 요구사항 편집기의 검증 상태에 반영된다.
    % 전제: Pi 전원 · 네트워크, can0 ↔ can1 연결, 배포된 sign_detector.elf (SWR-35 운영 조건)

    properties (Constant)
        PERIOD_MS = 100;   % CAN_PERIOD (SWR-04)
        TOL_MS = 10;       % SWR-04 허용 오차
    end

    methods (Test, TestTags = {'basic'})
        function normalOperation(tc)
            % SWR-04 0.1 s 주기 · SWR-11 ID/길이 · SWR-31 alive 누락 없음
            r = hil_measure("normal", 60);
            tc.verifyGreaterThan(r.n, 500, '60초 동안 프레임이 너무 적음');
            tc.verifyEqual(unique(r.id), "100", 'CAN ID는 0x100 (SWR-11)');
            tc.verifyEqual(unique(r.dlc), 4, '길이는 4 byte (SWR-11)');
            tc.verifyEqual(r.outOfTol, 0, sprintf('간격이 %d±%d ms를 벗어남 (SWR-04)', tc.PERIOD_MS, tc.TOL_MS));
            tc.verifyEqual(r.aliveGaps, 0, 'alive counter 누락 (SWR-31)');
            tc.verifyEqual(r.status(end), 1, '정상 동작 상태(1)로 끝나야 함 (SWR-34)');
        end

        function periodUnderCpuLoad(tc)
            % SWR-04: CPU 4코어 부하 중에도 송신 주기 유지
            r = hil_measure("load", 60);
            names = string({r.events.name});
            inLoad = r.t >= r.events(names == "load start").t & r.t <= r.events(names == "load end").t;
            dt = diff(r.t(inLoad)) * 1000;
            tc.verifyGreaterThan(numel(dt), 400, '부하 구간 프레임이 너무 적음');
            tc.verifyEqual(sum(abs(dt - tc.PERIOD_MS) > tc.TOL_MS), 0, '부하 중 간격이 기준을 벗어남 (SWR-04)');
            tc.verifyEqual(r.aliveGaps, 0, '부하 중 alive 누락 (SWR-31)');
        end

        function processingRate(tc)
            % SWR-21: 약 15 FPS로 인식 (ncnn_infer.cpp가 5초마다 남기는 처리 속도 로그)
            r = hil_measure("normal", 30);
            tc.assertGreaterThanOrEqual(numel(r.fps), 4, '처리 속도 로그가 부족함');
            tc.verifyGreaterThanOrEqual(mean(r.fps), 13.5, '평균 처리 속도가 약 15 FPS(-10%)보다 낮음 (SWR-21)');
            tc.verifyGreaterThanOrEqual(min(r.fps), 10, '5초 구간 중 처리 속도가 10 FPS 아래로 떨어짐');
        end

        function stallStopsSending(tc)
            % SWR-32: 인식이 1초 이상 멈추면 송신 중지, 다시 인식하면 재개
            % SWR-31: 송신하지 않은 주기에는 alive를 올리지 않음 → 재개 후 alive가 1만 증가
            r = hil_measure("stall", 20);
            names = string({r.events.name});
            tS = r.events(names == "stall start").t;
            tE = r.events(names == "stall end").t;
            iLast = find(r.t < tE, 1, 'last');
            stopDelay = r.t(iLast) - tS;
            tc.verifyGreaterThan(stopDelay, 0.8, '인식이 멈추고 너무 일찍 송신이 멈춤 (SWR-32)');
            tc.verifyLessThan(stopDelay, 1.15, '인식이 멈추고 1초 뒤에 송신이 멈춰야 함 (SWR-32)');
            iResume = find(r.t > tE, 1);
            tc.assertNotEmpty(iResume, '인식이 다시 되었는데 송신이 재개되지 않음');
            tc.verifyLessThan(r.t(iResume) - tE, 0.5, '인식 재개 후 0.5초 안에 송신이 재개되어야 함');
            tc.verifyEqual(mod(r.alive(iResume) - r.alive(iLast), 256), 1, '송신하지 않은 동안 alive가 증가함 (SWR-31)');
        end

        function bootStatus(tc)
            % SWR-34: 시작 직후부터 송신, 상태는 0(준비 중) → 1(정상)로만 바뀜
            r = hil_measure("boot", 15);
            tc.assertGreaterThan(r.n, 0, '시작 후 프레임이 없음');
            tc.verifyLessThan(r.firstFrameDelay, 2, '시작 후 2초 안에 송신이 시작되어야 함');
            tc.verifyTrue(all(diff(r.status) >= 0), '상태가 1에서 0으로 되돌아감');
            tc.verifyEqual(r.status(end), 1, '첫 인식 후 상태 1이어야 함 (SWR-34)');
        end
    end

    methods (Test, TestTags = {'fault'})
        function noModelStopsAfterBootTimeout(tc)
            % SWR-34: 모델을 못 읽으면 상태 0으로 송신하다가 10초(BOOT_SEC) 뒤 멈춤
            r = hil_measure("nomodel", 15);
            tc.assertGreaterThan(r.n, 0, '모델 없음에서도 처음에는 송신해야 함');
            tc.verifyTrue(all(r.status == 0), '모델이 없으면 상태는 0이어야 함');
            % BOOT_SEC는 프로그램 안의 첫 송신 주기부터 세므로 첫 프레임 기준 (프로세스 시작~첫 프레임 약 1.2 s는 제외)
            tc.verifyLessThan(r.t(end) - r.t(1), 10.2, '첫 프레임부터 10초 뒤 송신이 멈춰야 함 (BOOT_SEC)');
            tc.verifyLessThan(r.t(end) - r.t0, r.duration - 2, '측정이 끝나기 전에 송신이 멈춰 있어야 함');
        end

        function canFailureKeepsRunning(tc)
            % SWR-33: can0이 내려가도 프로그램은 계속 돌고, 다시 올라오면 재시작 없이 0.5초 안에 송신 재개
            % SWR-31: 멈춘 동안에도 alive는 증가 → 재개 후 첫 프레임에서 alive가 건너뜀
            r = hil_measure("canfail", 20);
            names = string({r.events.name});
            tDown = r.events(names == "can0 down").t;
            tUp = r.events(names == "can0 up").t;
            tc.verifyTrue(any(names == "app alive while can0 down: true"), 'can0 down 중 프로그램이 죽음 (SWR-33)');
            tc.verifyEqual(sum(r.t > tDown + 0.2 & r.t < tUp), 0, 'can0 down 동안 송신이 없어야 함');
            iResume = find(r.t > tUp - 0.2 & r.t > tDown + 0.2, 1);
            tc.assertNotEmpty(iResume, 'can0 up 후 송신이 재개되지 않음 (SWR-33)');
            tc.verifyLessThan(r.t(iResume) - tUp, 0.5, 'can0 up 후 0.5초 안에 재개되어야 함 (SWR-33)');
            tc.verifyGreaterThan(sum(r.t > tUp), 50, '재개 후 계속 송신해야 함');
            skipped = mod(r.alive(iResume) - r.alive(iResume - 1), 256) - 1;
            downCycles = (tUp - tDown) / 0.1;
            tc.verifyGreaterThan(skipped, 0.8 * downCycles, '멈춘 동안 alive가 증가해야 함 (SWR-31)');
        end
    end
end
