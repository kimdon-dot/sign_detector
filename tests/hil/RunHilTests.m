classdef RunHilTests < padv.Task
    % RunHilTests  Process Advisor 태스크: Raspberry Pi 실기 HIL 테스트(HilTest)를 실행한다
    %
    %   processmodel.m에서 DeployToPi 다음에 등록한다 (dependsOn). 배포가 다시 되면 이 태스크도 다시 실행된다.
    %   입력: tests/hil/HilTest.m, tests/hil/hil_measure.m, DeployToPi의 결과(배포 로그)
    %   결과 (PA_Results/hil/):
    %     hil_results.xml   JUnit 형식 (CI 도구에서 읽음)
    %     hil_log.txt       전체 출력 (측정값 요약, 실패 이유)
    %     measurements/     시나리오별 측정 원본 (.mat, hil_measure 결과)
    %   Tag = "basic"이면 Pi 설정을 바꾸지 않는 테스트만 (fault 태그 제외). 기본은 전부 (약 5분)
    %
    %   전제: Pi 전원 · 네트워크, can0 ↔ can1 연결, DeployToPi로 배포된 실행 파일

    properties
        TestClass (1, 1) string = "HilTest"
        Tag (1, 1) string = ""
    end

    methods
        function obj = RunHilTests(options)
            arguments
                options.Name = "RunHilTests"
                options.Title = "Run HIL Tests"
            end
            obj@padv.Task(options.Name, ...
                Title = options.Title, ...
                RequiredIterationArtifactType = "project", ...
                IterationQuery = "padv.builtin.query.FindProjectFile", ...
                InputQueries = padv.builtin.query.FindFileWithAddress(Type = "m_file", ...
                    Path = {fullfile('tests', 'hil', 'HilTest.m'), fullfile('tests', 'hil', 'hil_measure.m')}), ...
                DescriptionText = "Raspberry Pi 실기에서 HIL 테스트(HilTest)를 실행합니다. CAN 송신을 can1에서 기록해 요구사항별로 판정합니다.");
            obj.OutputDirectory = fullfile('$DEFAULTOUTPUTDIR$', 'hil');
        end

        function taskResult = run(obj, ~)
            taskResult = padv.TaskResult;
            outDir = obj.OutputDirectory(1);
            if contains(outDir, "$"), outDir = obj.resolvePath(outDir); end   % 토큰은 Process Advisor 실행 중에만 풀림
            outDir = char(outDir);
            measDir = fullfile(outDir, 'measurements');
            if isfolder(measDir), rmdir(measDir, 's'); end   % 이번 실행의 측정만 남김
            mkdir(measDir);
            xmlFile = fullfile(outDir, 'hil_results.xml');
            logFile = fullfile(outDir, 'hil_log.txt');

            % hil_measure가 측정 원본을 tests/hil/results 대신 여기에 저장하게 함
            oldDir = getenv('HIL_RESULT_DIR');
            setenv('HIL_RESULT_DIR', measDir);
            restoreEnv = onCleanup(@() setenv('HIL_RESULT_DIR', oldDir));

            suite = matlab.unittest.TestSuite.fromClass(meta.class.fromName(obj.TestClass));
            if obj.Tag ~= ""
                suite = suite.selectIf('Tag', obj.Tag);
            end
            runner = matlab.unittest.TestRunner.withTextOutput;
            runner.addPlugin(matlab.unittest.plugins.XMLPlugin.producingJUnitFormat(xmlFile));

            fprintf('[hil] %s 테스트 %d개 실행\n', obj.TestClass, numel(suite));
            log = evalc('res = runner.run(suite);');
            clear restoreEnv

            % 요약: 테스트별 결과
            passed = [res.Passed];
            summary = "";
            for i = 1:numel(res)
                st = "PASS";
                if ~passed(i), st = "FAIL"; end
                summary = summary + sprintf('%-50s %s %5.0f s\n', res(i).Name, st, res(i).Duration);
            end
            fid = fopen(logFile, 'w', 'n', 'UTF-8');
            fprintf(fid, '%s\n%s', summary, log);
            fclose(fid);
            fprintf('%s', summary);

            mats = dir(fullfile(measDir, '*.mat'));
            taskResult.OutputPaths = [string(xmlFile), string(logFile), string(fullfile(measDir, {mats.name}))];
            taskResult.Values.Pass = nnz(passed);
            taskResult.Values.Fail = nnz(~passed);
            if any(~passed)
                taskResult.Status = padv.TaskStatus.Fail;
            end
        end
    end
end
