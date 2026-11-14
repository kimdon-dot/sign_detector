function processmodel(pm)
    % Process Advisor 파이프라인 (CI 전체 단계)

    arguments
        pm padv.ProcessModel
    end

    %% Include/Exclude Tasks in processmodel

    includeModelMaintainabilityMetricTask = true;
    includeModelTestingMetricTask = true;
    includeModelStandardsTask = true;
    includeDesignErrorDetectionTask = false;
    includeFindClones = true;
    includeModelComparisonTask = false;
    includeSDDTask = true;
    includeSimulinkWebViewTask = true;
    includeTestsPerTestCaseTask = true;
    includeMergeTestResultsTask = true && includeTestsPerTestCaseTask;   % 병합할 MIL 결과가 있어야 함
    includeGenerateCodeTask = true;
    includeAnalyzeModelCode = true && padv.internal.util.isPolyspaceSupported && exist('polyspaceroot','file');
    includeProveCodeQuality = true && padv.internal.util.isPolyspaceSupported && (~isempty(ver('pscodeprover')) || ~isempty(ver('pscodeproverserver')));
    includeCodeInspection = false;
    includeGenerateRequirementsReport = false;
    includeIndexModelsTask = false;
    % Pi 배포 + HIL 테스트 (tests/hil). Pi 전원 · can0↔can1 연결 필요, 약 7분
    includeHilTasks = true;

    %% Define Shared Path Variables

    pm.DefaultOutputDirectory = fullfile('$PROJECTROOT$', 'PA_Results');
    defaultResultPath = fullfile( ...
        '$DEFAULTOUTPUTDIR$','$ITERATIONARTIFACT$');

    %% Define Shared Queries
    findModels = padv.builtin.query.FindModels(Name="ModelsQuery");
    findSlModels = padv.builtin.query.FindArtifacts(ArtifactType="sl_model_file");
    findModelsWithTests = padv.builtin.query.FindModelsWithTestCases(Parent=findModels);
    findTestsForModel = padv.builtin.query.FindTestCasesForModel(Parent=findModels);

    %% Register Tasks

    %% Collect Model Maintainability Metrics
    if includeModelMaintainabilityMetricTask
        mmMetricTask = pm.addTask(padv.builtin.task.CollectMetrics());
    end

    %% Check modeling standards
    if includeModelStandardsTask
        maTask = pm.addTask(padv.builtin.task.RunModelStandards(IterationQuery=findModels));
        maTask.ReportPath = fullfile( ...
            defaultResultPath,'model_standards_results');
        % 검사 목록: checks/model_standards.json (기본 목록 - R2026b에 없는 hisl_0311)
        maTask.addInputQueries(padv.builtin.query.FindFileWithAddress( ...
            Type='ma_config_file', Path=fullfile('checks','model_standards.json')));
    end

    %% Detect design errors
    if includeDesignErrorDetectionTask
        dedTask = pm.addTask(padv.builtin.task.DetectDesignErrors(IterationQuery=findModels)); %#ok<*UNRCH>
        dedTask.ReportFilePath = fullfile( ...
            defaultResultPath, 'design_error_detections','$ITERATIONARTIFACT$_DED');
    end

    %% Generate clone detection reports
    if includeFindClones
        %Across Model Clones Instance
        acrossModelCloneDetectTask = pm.addTask(padv.builtin.task.FindClones(Name = "FindAcrossModelClones", ...
            IterationQuery=findSlModels,Title=message('padv_spkg:builtin_text:FindClonesAcrossModelTitle').getString()));
        acrossModelCloneDetectTask.ReportPath = fullfile(defaultResultPath,'findAcrossModelClones');
        acrossModelCloneDetectTask.AcrossModelReportName = "$ITERATIONARTIFACT$_AcrossModelClonesReport";
        acrossModelCloneDetectTask.DetectLibraryClones = false;
        %Library Clones Instance
        libCloneDetectTask = pm.addTask(padv.builtin.task.FindClones(Name = "FindLibraryClones", ...
            IterationQuery=findSlModels,Title=message('padv_spkg:builtin_text:FindLibraryClonesTitle').getString()));
        libCloneDetectTask.ReportPath = fullfile(defaultResultPath,'findLibraryClones');
        libCloneDetectTask.LibraryReportName = "$ITERATIONARTIFACT$_LibraryClonesReport";
        libCloneDetectTask.DetectClonesAcrossModel = false;
    end

    %% Generate Model Comparison
    if includeModelComparisonTask
        mdlCompTask = pm.addTask(padv.builtin.task.GenerateModelComparison(IterationQuery=findModels));
        mdlCompTask.ReportPath = fullfile( ...
            defaultResultPath,'model_comparison');
    end

    %% Generate SDD report (System Design Description)
    if includeSDDTask
        sddTask = pm.addTask(padv.builtin.task.GenerateSDDReport(IterationQuery=findModels));
        sddTask.ReportPath = fullfile( ...
            defaultResultPath,'system_design_description');
        sddTask.ReportName = '$ITERATIONARTIFACT$_SDD';
    end

    %% Generate Simulink web view
    if includeSimulinkWebViewTask
        slwebTask = pm.addTask(padv.builtin.task.GenerateSimulinkWebView(IterationQuery=findModels));
        slwebTask.ReportPath = fullfile(defaultResultPath,'webview');
        slwebTask.ReportName = '$ITERATIONARTIFACT$_webview';
    end

    %% Run tests per test case
    if includeTestsPerTestCaseTask
        milTask = pm.addTask(padv.builtin.task.RunTestsPerTestCase(IterationQuery=findTestsForModel));
        milTask.OutputDirectory = fullfile( ...
            '$PROJECTROOT$','PA_Results','test_results');
    end

    %% Merge test results
    if includeTestsPerTestCaseTask && includeMergeTestResultsTask
        mergeTestTask = pm.addTask(padv.builtin.task.MergeTestResults(IterationQuery=findModelsWithTests, PredecessorTask=milTask));
        mergeTestTask.ReportPath = fullfile( ...
            '$PROJECTROOT$','PA_Results','test_results');
    end

    %% Collect Model Testing Metrics
    if includeModelTestingMetricTask
        mtMetricTask = pm.addTask(padv.builtin.task.CollectMetrics(Name="ModelTestingMetrics", IterationQuery=padv.builtin.query.FindUnits));
        mtMetricTask.Title = message('padv_spkg:builtin_text:ModelTestingMetricDemoTaskTitle').getString();
        mtMetricTask.Dashboard = "ModelUnitTesting";
        mtMetricTask.ReportName = "$ITERATIONARTIFACT$_ModelTesting";
    end

    %% Generate Code
    if includeGenerateCodeTask
        codegenTask = pm.addTask(padv.builtin.task.GenerateCode(IterationQuery=findModels));
    end

    %% Check coding standards
    if includeGenerateCodeTask && includeAnalyzeModelCode
        psbfTask = pm.addTask(padv.builtin.task.AnalyzeModelCode(IterationQuery=findModels, PredecessorTask=codegenTask));
        psbfTask.ResultDir = fullfile(defaultResultPath,'bug_finder');
        psbfTask.ReportPath = fullfile(defaultResultPath,'bug_finder');
    end

    %% Prove Code Quality
    if includeGenerateCodeTask && includeProveCodeQuality
        pscpTask = pm.addTask(padv.builtin.task.AnalyzeModelCode(Name="ProveCodeQuality", IterationQuery=findModels, PredecessorTask=codegenTask));
        pscpTask.Title = message('padv_spkg:builtin_text:PSCPDemoTaskTitle').getString();
        pscpTask.VerificationMode = "CodeProver";
        pscpTask.ResultDir = string(fullfile(defaultResultPath,'code_prover'));
        pscpTask.Reports = ["Developer", "CallHierarchy", "VariableAccess"];
        pscpTask.ReportPath = string(fullfile(defaultResultPath,'code_prover'));
        pscpTask.ReportNames = [...
            "$ITERATIONARTIFACT$_Developer", ...
            "$ITERATIONARTIFACT$_CallHierarchy", ...
            "$ITERATIONARTIFACT$_VariableAccess"];
    end

    %% Inspect Code
    if includeGenerateCodeTask && includeCodeInspection
        slciTask = pm.addTask(padv.builtin.task.RunCodeInspection(IterationQuery=findModels, PredecessorTask=codegenTask));
        slciTask.ReportFolder = fullfile(defaultResultPath,'code_inspection');
    end

    %% Deploy to Raspberry Pi → Run HIL tests
    % 모델 · C++가 바뀌면 다시 배포, 배포나 HilTest.m이 바뀌면 HIL 다시 실행
    if includeHilTasks
        deployTask = pm.addTask(DeployToPi());
        hilTask = pm.addTask(RunHilTests());
        hilTask.addInputQueries(padv.builtin.query.GetOutputsOfDependentTask(Task=deployTask));
    end

    %% Index Models
    if includeIndexModelsTask
        imTask = pm.addTask(padv.builtin.task.IndexModels(IterationQuery=findModels));
    end

    %% Generate Requirements report
    if includeGenerateRequirementsReport
        rqmtTask = pm.addTask(padv.builtin.task.GenerateRequirementsReport());
    end

    %% Set Task relationships

    %% Set Task Dependencies
    if includeGenerateCodeTask && includeCodeInspection
        slciTask.dependsOn(codegenTask);
    end
    if includeGenerateCodeTask && includeAnalyzeModelCode
        psbfTask.dependsOn(codegenTask);
    end
    if includeGenerateCodeTask && includeProveCodeQuality
        pscpTask.dependsOn(codegenTask);
    end
    if includeTestsPerTestCaseTask && includeMergeTestResultsTask
        mergeTestTask.dependsOn(milTask, "WhenStatus",{'Pass','Fail'});
    end
    if includeHilTasks
        hilTask.dependsOn(deployTask);   % 배포가 성공해야 HIL 테스트
    end

    %% Set Task Run-Order
    if includeMergeTestResultsTask && includeModelTestingMetricTask
        mtMetricTask.runsAfter(mergeTestTask);
    end
    if includeSimulinkWebViewTask && includeModelMaintainabilityMetricTask
        slwebTask.runsAfter(mmMetricTask);
    end
    if includeModelStandardsTask && includeModelMaintainabilityMetricTask
        maTask.runsAfter(mmMetricTask);
    end
    if includeModelStandardsTask && includeSimulinkWebViewTask
        maTask.runsAfter(slwebTask);
    end
    if includeModelStandardsTask && includeFindClones
        acrossModelCloneDetectTask.runsAfter(maTask);
        libCloneDetectTask.runsAfter(maTask);
    end
    if includeDesignErrorDetectionTask && includeModelStandardsTask
        dedTask.runsAfter(maTask);
    end
    if includeModelComparisonTask && includeModelStandardsTask
        mdlCompTask.runsAfter(maTask);
    end
    if includeSDDTask && includeModelStandardsTask
        sddTask.runsAfter(maTask);
    end
    if includeTestsPerTestCaseTask && includeModelStandardsTask
        milTask.runsAfter(maTask);
    end
    if includeGenerateCodeTask && includeAnalyzeModelCode && includeProveCodeQuality
        pscpTask.runsAfter(psbfTask);
    end
    % 코드 생성은 정적 검사 · SDD · MIL 테스트 · 클론 탐지 · 메트릭 뒤에
    if includeGenerateCodeTask && includeModelStandardsTask
        codegenTask.runsAfter(maTask);
    end
    if includeGenerateCodeTask && includeSDDTask
        codegenTask.runsAfter(sddTask);
    end
    if includeGenerateCodeTask && includeMergeTestResultsTask
        codegenTask.runsAfter(mergeTestTask);
    end
    if includeGenerateCodeTask && includeFindClones
        codegenTask.runsAfter(acrossModelCloneDetectTask);
        codegenTask.runsAfter(libCloneDetectTask);
    end
    if includeGenerateCodeTask && includeModelTestingMetricTask
        codegenTask.runsAfter(mtMetricTask);
    end
    % Code Inspector는 Bug Finder 뒤에 (실행 의존성 없이 순서만)
    if includeGenerateCodeTask && includeAnalyzeModelCode ...
            && includeCodeInspection
        slciTask.runsAfter(psbfTask);
    end
    if includeGenerateRequirementsReport && includeMergeTestResultsTask
        rqmtTask.runsAfter(mergeTestTask);
    end
    % HIL은 맨 마지막: 정적 검사 · MIL 테스트 · 코드 생성 뒤에 Pi 배포
    if includeHilTasks && includeGenerateCodeTask
        deployTask.runsAfter(codegenTask);
    end
    if includeHilTasks && includeMergeTestResultsTask
        deployTask.runsAfter(mergeTestTask);
    end
    if includeHilTasks && includeGenerateCodeTask && includeAnalyzeModelCode
        deployTask.runsAfter(psbfTask);
    end

    % Simulink Test 애드온이 있으면 모델 테스트 프로세스 추가
    if(~isempty(which('pasltest.addProcess')))
        pasltest.addProcess(pm);
    end

end
