classdef DeployToPi < padv.Task
    % Process Advisor 태스크: sign_detector를 Pi에 빌드 · 배포. 결과: PA_Results/hil/deploy_log.txt

    methods
        function obj = DeployToPi()
            obj@padv.Task("DeployToPi", ...
                Title = "Deploy to Raspberry Pi", ...
                RequiredIterationArtifactType = "project", ...
                IterationQuery = "padv.builtin.query.FindProjectFile", ...
                DescriptionText = "sign_detector를 Raspberry Pi용으로 빌드해 배포합니다 (참조 모델 강제 재빌드).");
            obj.OutputDirectory = fullfile('$DEFAULTOUTPUTDIR$', 'hil');

            % 입력 파일: 이 중 하나라도 바뀌면 Process Advisor가 다시 배포함 (파일을 더하면 여기에도 추가)
            f = @fullfile;
            obj.addInputQueries([ ...
                padv.builtin.query.FindFileWithAddress(Type = "sl_model_file", Path = { ...
                    f('models', 'sign_detector.slx'), f('models', 'unit_recognize.slx'), ...
                    f('models', 'unit_decide.slx'),   f('models', 'unit_can_sender.slx')}), ...
                padv.builtin.query.FindFileWithAddress(Type = "sl_data_dictionary_file", Path = { ...
                    f('models', 'sign_detector.sldd')}), ...
                padv.builtin.query.FindFileWithAddress(Type = "m_file", Path = { ...
                    f('pi', 'pi_postcodegen.m'), f('pi', 'ncnn', 'set_ncnn_model_dir.m')}), ...
                padv.builtin.query.FindFileWithAddress(Path = { ...
                    f('pi', 'ncnn', 'ncnn_infer.cpp'), f('pi', 'ncnn', 'ncnn_infer.h'), f('pi', 'libcamera_compat.h')})]);
        end

        function taskResult = run(obj, ~)
            outDir = char(obj.resolvePath(obj.OutputDirectory(1)));
            if ~isfolder(outDir), mkdir(outDir); end
            logFile = fullfile(outDir, 'deploy_log.txt');
            m = 'sign_detector';

            % ── 1. 빌드 전에 열려 있던 모델 기억 ──
            before = openModels();

            % ── 2. 빌드 설정 바꾸기 (메모리에서만, 4에서 되돌림) ──
            load_system(m);
            cs = getActiveConfigSet(m);
            % 빌드만 하고 Pi에서 실행은 안 함 (모델 설정은 "Build and run". 실행은 HilTest가 직접)
            oldAction = codertarget.data.getParameterValue(cs, 'Runtime.BuildAction');
            codertarget.data.setParameterValue(cs, 'Runtime.BuildAction', 'Build');
            % 참조 모델까지 강제로 다시 빌드 (C++만 바뀌면 Simulink가 몰라서 Pi에 예전 코드가 남음)
            oldUpdate = get_param(m, 'UpdateModelReferenceTargets');
            set_param(m, 'UpdateModelReferenceTargets', 'Force');

            % ── 3. 빌드 · 배포 (출력은 deploy_log.txt에) ──
            if isfile(logFile), delete(logFile); end
            diary(logFile);
            try
                slbuild(m);
                ok = true;
            catch err
                disp(err.getReport('extended', 'hyperlinks', 'off'));
                ok = false;
            end
            diary off

            % ── 4. 정리: 설정 되돌리기, 빌드가 새로 연 모델 닫기 ──
            % (열어 두면 이어서 도는 메트릭 태스크가 참조 모델에서 Error를 냄)
            codertarget.data.setParameterValue(cs, 'Runtime.BuildAction', oldAction);
            set_param(m, 'UpdateModelReferenceTargets', oldUpdate);
            for b = setdiff(openModels(), before)
                close_system(b, 0);   % 0: 저장 안 함
            end

            % ── 5. Process Advisor에 결과 알리기 ──
            taskResult = padv.TaskResult;
            taskResult.OutputPaths = string(logFile);
            if ok
                taskResult.Values.Pass = 1;
            else
                taskResult.Status = padv.TaskStatus.Fail;
                taskResult.Values.Fail = 1;
            end
        end
    end
end

function names = openModels()
    % 지금 열려 있는 모델 · 라이브러리 이름 (1×N string)
    names = reshape(string(get_param(Simulink.allBlockDiagrams(), 'Name')), 1, []);
end
