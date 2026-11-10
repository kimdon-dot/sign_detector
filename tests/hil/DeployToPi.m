classdef DeployToPi < padv.Task
    % DeployToPi  Process Advisor 태스크: 최상위 모델을 Raspberry Pi용으로 빌드해 Pi에 실행 파일을 만든다 (HIL 앞 단계)
    %
    %   processmodel.m에서 pm.addTask(DeployToPi()) 로 등록한다. 뒤이어 RunHilTests가 이 실행 파일로 HIL 테스트를 한다.
    %
    %   입력: 모델 4개 · 데이터 사전 및 pi/ 아래 C/C++ 소스 · 빌드 훅 (생성자에 목록).
    %         이 중 하나라도 바뀌면 Process Advisor가 이 태스크를 '오래됨'으로 표시하고 다시 실행한다.
    %   빌드: C++만 바뀌면 Simulink 증분 빌드가 알아채지 못해 Pi에 예전 코드가 남으므로(HIL에서 실제로 겪음)
    %         참조 모델까지 강제로 다시 빌드한다. 설정은 메모리에서만 바꾸고 모델은 저장하지 않는다.
    %   확인: 빌드 후 Pi의 실행 파일 수정 시각이 빌드 시작 이후인지 본다.
    %   결과: PA_Results/hil/deploy_log.txt (빌드 로그, 실행 파일 정보)
    %
    %   전제: Pi 전원 · 네트워크 (raspberrypi 연결 설정이 MATLAB에 저장되어 있어야 함)

    properties
        Model (1, 1) string = "sign_detector"
        % Pi의 실행 파일. hil_measure의 기본 Elf 경로와 같아야 함 (MATLAB이 코드 생성 폴더 경로를 따라 정함)
        Elf (1, 1) string = "~/MATLAB_ws/R2026b/C/Users/don/Desktop/project/cache/sign_detector/sign_detector.elf"
        % 참조 모델까지 강제로 다시 빌드 (C++ 변경 반영)
        ForceRebuild (1, 1) logical = true
    end

    methods
        function obj = DeployToPi(options)
            arguments
                options.Name = "DeployToPi"
                options.Title = "Deploy to Raspberry Pi"
            end
            obj@padv.Task(options.Name, ...
                Title = options.Title, ...
                RequiredIterationArtifactType = "project", ...
                IterationQuery = "padv.builtin.query.FindProjectFile", ...
                DescriptionText = "최상위 모델을 Raspberry Pi용으로 빌드해 Pi에 실행 파일을 만듭니다 (참조 모델 강제 재빌드).");
            obj.OutputDirectory = fullfile('$DEFAULTOUTPUTDIR$', 'hil');
            % 입력 (태스크 입력으로는 FindArtifacts를 쓸 수 없어 파일을 직접 지정). 파일을 더하면 여기에도 추가
            m = @(f) fullfile('models', f);
            obj.addInputQueries([ ...
                padv.builtin.query.FindFileWithAddress(Type = "sl_model_file", ...
                    Path = {m('sign_detector.slx'), m('unit_recognize.slx'), m('unit_decide.slx'), m('unit_can_sender.slx')}), ...
                padv.builtin.query.FindFileWithAddress(Type = "sl_data_dictionary_file", Path = {m('sign_detector.sldd')}), ...
                padv.builtin.query.FindFileWithAddress(Type = "m_file", ...
                    Path = {fullfile('pi', 'pi_postcodegen.m'), fullfile('pi', 'ncnn', 'set_ncnn_model_dir.m')}), ...
                padv.builtin.query.FindFileWithAddress(Path = {fullfile('pi', 'ncnn', 'ncnn_infer.cpp'), ...
                    fullfile('pi', 'ncnn', 'ncnn_infer.h'), fullfile('pi', 'libcamera_compat.h')})]);
        end

        function taskResult = run(obj, ~)
            taskResult = padv.TaskResult;
            outDir = obj.OutputDirectory(1);
            if contains(outDir, "$"), outDir = obj.resolvePath(outDir); end   % 토큰은 Process Advisor 실행 중에만 풀림
            outDir = char(outDir);
            if ~isfolder(outDir), mkdir(outDir); end
            logFile = fullfile(outDir, 'deploy_log.txt');

            h = connectPi();
            piNow = str2double(system(h, 'date +%s'));

            m = char(obj.Model);
            loadedBefore = loadedModels();   % 빌드가 새로 연 참조 모델 · 라이브러리는 끝나고 닫음
            wasLoaded = bdIsLoaded(m);
            load_system(m);
            if wasLoaded && strcmp(get_param(m, 'Dirty'), 'on')
                error('DeployToPi:dirty', '%s 모델에 저장하지 않은 변경이 있습니다. 저장한 뒤 다시 실행하세요.', m);
            end
            cs = getActiveConfigSet(m);
            oldAction = codertarget.data.getParameterValue(cs, 'Runtime.BuildAction');
            oldUpdate = get_param(m, 'UpdateModelReferenceTargets');
            restoreModel = onCleanup(@() restore(m, cs, oldAction, oldUpdate, wasLoaded, loadedBefore));
            codertarget.data.setParameterValue(cs, 'Runtime.BuildAction', 'Build');
            if obj.ForceRebuild
                setQuiet(m, 'UpdateModelReferenceTargets', 'Force');
            end

            fprintf('[deploy] %s 빌드 시작 (참조 모델 강제 재빌드: %d)\n', m, obj.ForceRebuild);
            t = tic;
            ok = true;
            try
                buildLog = evalc('slbuild(m)');
            catch e
                ok = false;
                buildLog = e.getReport('extended', 'hyperlinks', 'off');
            end
            sec = toc(t);
            clear restoreModel

            % Pi의 실행 파일이 이번 빌드로 바뀌었는지
            elfInfo = strtrim(system(h, char("ls -l --time-style=+%F_%T " + obj.Elf + " 2>&1; true")));
            elfTime = str2double(system(h, char("stat -c %Y " + obj.Elf + " 2>/dev/null || echo NaN")));
            fresh = ok && elfTime >= piNow - 2;

            fid = fopen(logFile, 'w', 'n', 'UTF-8');
            fprintf(fid, '모델: %s\n빌드: %s (%.0f s)\n실행 파일: %s\n갱신됨: %d\n\n', ...
                m, string(ok), sec, elfInfo, fresh);
            fprintf(fid, '%s', buildLog);
            fclose(fid);
            taskResult.OutputPaths = string(logFile);

            if ~ok
                errs = regexp(buildLog, '(fatal error[^\n]*|error:[^\n]*|undefined reference[^\n]*)', 'match');
                fprintf('[deploy] 빌드 실패 (%.0f s)\n', sec);
                fprintf('   %s\n', errs{1:min(end, 10)});
                taskResult.Status = padv.TaskStatus.Fail;
                taskResult.Values.Fail = 1;
            elseif ~fresh
                fprintf('[deploy] 빌드는 끝났지만 Pi의 실행 파일이 갱신되지 않음: %s\n', elfInfo);
                taskResult.Status = padv.TaskStatus.Fail;
                taskResult.Values.Fail = 1;
            else
                fprintf('[deploy] 완료 (%.0f s): %s\n', sec, elfInfo);
                taskResult.Values.Pass = 1;
            end
        end
    end
end

function h = connectPi()
try
    h = raspberrypi;
catch e
    error('DeployToPi:noPi', 'Raspberry Pi에 연결할 수 없습니다 (전원 · 네트워크 확인): %s', e.message);
end
end

function restore(m, cs, oldAction, oldUpdate, wasLoaded, loadedBefore)
% 메모리에서 바꾼 빌드 설정을 되돌림. 처음부터 열려 있던 모델은 저장 안 됨 상태로 되돌리고, 아니면 닫음.
% 빌드 중 새로 열린 참조 모델 · 라이브러리도 닫음: 열린 채로 두면 같은 세션에서 이어 도는
% 메트릭 태스크(Collect Model Maintainability/Testing Metrics)가 참조 모델에서 Error가 남 (다시 돌리면 통과)
if bdIsLoaded(m)
    codertarget.data.setParameterValue(cs, 'Runtime.BuildAction', oldAction);
    setQuiet(m, 'UpdateModelReferenceTargets', oldUpdate);
    if wasLoaded
        set_param(m, 'Dirty', 'off');
    else
        close_system(m, 0);
    end
end
for b = setdiff(loadedModels(), loadedBefore)
    if bdIsLoaded(b) && strcmp(get_param(b, 'Dirty'), 'off')
        close_system(b, 0);
    end
end
end

function names = loadedModels()
names = string(get_param(Simulink.allBlockDiagrams(), 'Name'));
names = reshape(names, 1, []);
end

function setQuiet(m, name, value)
% UpdateModelReferenceTargets는 R2026b에서 '제거 예정' 경고를 냄. 대체 설정이 아직 없어 경고만 끔
% (참조 모델 강제 재빌드는 C++ 변경 반영에 필요)
s = warning('off', 'all');
restoreWarn = onCleanup(@() warning(s));
set_param(m, name, value);
end
