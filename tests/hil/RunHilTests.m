classdef RunHilTests < padv.Task
    % Process Advisor 태스크: HilTest 실행. 결과: PA_Results/hil/hil_results.xml (JUnit), hil_log.txt

    methods
        function obj = RunHilTests()
            obj@padv.Task("RunHilTests", ...
                Title = "Run HIL Tests", ...
                RequiredIterationArtifactType = "project", ...
                IterationQuery = "padv.builtin.query.FindProjectFile", ...
                InputQueries = padv.builtin.query.FindFileWithAddress(Type = "m_file", ...
                    Path = {fullfile('tests', 'hil', 'HilTest.m')}), ...
                DescriptionText = "Raspberry Pi에서 HilTest를 실행합니다.");
            obj.OutputDirectory = fullfile('$DEFAULTOUTPUTDIR$', 'hil');
        end

        function taskResult = run(obj, ~)
            outDir = char(obj.resolvePath(obj.OutputDirectory(1)));
            if ~isfolder(outDir), mkdir(outDir); end
            xmlFile = fullfile(outDir, 'hil_results.xml');
            logFile = fullfile(outDir, 'hil_log.txt');

            % ── 1. 테스트 실행 (JUnit XML도 같이 만듦) ──
            suite = matlab.unittest.TestSuite.fromClass(?HilTest); %#ok<NASGU> evalc 안에서 씀
            runner = matlab.unittest.TestRunner.withTextOutput;
            runner.addPlugin(matlab.unittest.plugins.XMLPlugin.producingJUnitFormat(xmlFile));
            log = evalc('results = runner.run(suite);');

            % ── 2. 로그 저장 ──
            fid = fopen(logFile, 'w', 'n', 'UTF-8');
            fprintf(fid, '%s', log);
            fclose(fid);
            disp(table(results));

            % ── 3. Process Advisor에 결과 알리기 ──
            taskResult = padv.TaskResult;
            taskResult.OutputPaths = [string(xmlFile), string(logFile)];
            taskResult.Values.Pass = nnz([results.Passed]);
            taskResult.Values.Fail = nnz(~[results.Passed]);
            if any(~[results.Passed])
                taskResult.Status = padv.TaskStatus.Fail;
            end
        end
    end
end
