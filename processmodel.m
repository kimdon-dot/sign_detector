function processmodel(pm)
    % Defines the project's processmodel

    arguments
        pm padv.ProcessModel
    end

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Include/Exclude Tasks in processmodel
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    includeModelMaintainabilityMetricTask = true;
    includeModelTestingMetricTask = true;
    includeModelStandardsTask = true;
    includeDesignErrorDetectionTask = false;
    includeFindClones = true;
    includeModelComparisonTask = false;
    includeSDDTask = true;
    includeSimulinkWebViewTask = true;
    includeTestsPerTestCaseTask = true;
    includeMergeTestResultsTask = true;
    includeGenerateCodeTask = true;
    includeAnalyzeModelCode = true && padv.internal.util.isPolyspaceSupported && exist('polyspaceroot','file');
    includeProveCodeQuality = true && padv.internal.util.isPolyspaceSupported && (~isempty(ver('pscodeprover')) || ~isempty(ver('pscodeproverserver')));
    includeCodeInspection = false;
    includeGenerateRequirementsReport = false;
    includeIndexModelsTask = false;

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Define Shared Path Variables
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    % Set default root directory for task results
    pm.DefaultOutputDirectory = fullfile('$PROJECTROOT$', 'PA_Results');
    defaultResultPath = fullfile( ...
        '$DEFAULTOUTPUTDIR$','$ITERATIONARTIFACT$');

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Define Shared Queries
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    findModels = padv.builtin.query.FindModels(Name="ModelsQuery");
    findSlModels = padv.builtin.query.FindArtifacts(ArtifactType="sl_model_file");
    findModelsWithTests = padv.builtin.query.FindModelsWithTestCases(Parent=findModels);
    findTestsForModel = padv.builtin.query.FindTestCasesForModel(Parent=findModels);

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Register Tasks
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

    %% Collect Model Maintainability Metrics
    % Tools required: Simulink Check
    if includeModelMaintainabilityMetricTask
        mmMetricTask = pm.addTask(padv.builtin.task.CollectMetrics());
    end

    %% Check modeling standards
    % Tools required: Model Advisor
    if includeModelStandardsTask
        maTask = pm.addTask(padv.builtin.task.RunModelStandards(IterationQuery=findModels));
        maTask.ReportPath = fullfile( ...
            defaultResultPath,'model_standards_results');
    end

    %% Detect design errors
    % Tools required: Simulink Design Verifier
    if includeDesignErrorDetectionTask
        dedTask = pm.addTask(padv.builtin.task.DetectDesignErrors(IterationQuery=findModels)); %#ok<*UNRCH>
        dedTask.ReportFilePath = fullfile( ...
            defaultResultPath, 'design_error_detections','$ITERATIONARTIFACT$_DED');
    end

    %% Generate clone detection reports
    % Tools required: Clone Detector
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
    %  Tools required: Simulink Report Generator
    if includeSDDTask
        sddTask = pm.addTask(padv.builtin.task.GenerateSDDReport(IterationQuery=findModels));
        sddTask.ReportPath = fullfile( ...
            defaultResultPath,'system_design_description');
        sddTask.ReportName = '$ITERATIONARTIFACT$_SDD';
    end

    %% Generate Simulink web view
    % Tools required: Simulink Report Generator
    if includeSimulinkWebViewTask
        slwebTask = pm.addTask(padv.builtin.task.GenerateSimulinkWebView(IterationQuery=findModels));
        slwebTask.ReportPath = fullfile(defaultResultPath,'webview');
        slwebTask.ReportName = '$ITERATIONARTIFACT$_webview';
    end

    %% Run tests per test case
    % Tools required: Simulink Test
    if includeTestsPerTestCaseTask
        milTask = pm.addTask(padv.builtin.task.RunTestsPerTestCase(IterationQuery=findTestsForModel));
        % Configure the tests per testcase task
        milTask.OutputDirectory = fullfile( ...
            '$PROJECTROOT$','PA_Results','test_results');
    end

    %% Merge test results
    % Tools required: Simulink Test (and optionally Simulink Coverage)
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
    % Tools required: Embedded Coder
    % By default, we generate code for all models in the project;
    if includeGenerateCodeTask
        codegenTask = pm.addTask(padv.builtin.task.GenerateCode(IterationQuery=findModels));
    end

    %% Check coding standards
    % Tools required: Polyspace Bug Finder
    if includeGenerateCodeTask && includeAnalyzeModelCode
        psbfTask = pm.addTask(padv.builtin.task.AnalyzeModelCode(IterationQuery=findModels, PredecessorTask=codegenTask));
        psbfTask.ResultDir = fullfile(defaultResultPath,'bug_finder');
        psbfTask.ReportPath = fullfile(defaultResultPath,'bug_finder');
    end

    %% Prove Code Quality
    % Tools required: Polyspace Code Prover
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
    % Tools required: Simulink Code Inspector
    if includeGenerateCodeTask && includeCodeInspection
        slciTask = pm.addTask(padv.builtin.task.RunCodeInspection(IterationQuery=findModels, PredecessorTask=codegenTask));
        slciTask.ReportFolder = fullfile(defaultResultPath,'code_inspection');
    end

    %% Index Models
    if includeIndexModelsTask
        imTask = pm.addTask(padv.builtin.task.IndexModels(IterationQuery=findModels));
    end

    %% Generate Requirements report
    % Tools required: Requirements Toolbox
    if includeGenerateRequirementsReport
        rqmtTask = pm.addTask(padv.builtin.task.GenerateRequirementsReport());
    end

    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %% Set Task relationships
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
    % Set the code generation task to always run after Model Standards,
    % System Design Description, Test tasks, Clone Detection, and Model Testing Metrics
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
    % Both the Polyspace Bug Finder (PSBF) and the Simulink Code Inspector
    % (SLCI) tasks depend on the code generation tasks. SLCI task is set to
    % run after the PSBF task without establishing an execution dependency
    % by using 'runsAfter'.
    if includeGenerateCodeTask && includeAnalyzeModelCode ...
            && includeCodeInspection
        slciTask.runsAfter(psbfTask);
    end
    if includeGenerateRequirementsReport && includeMergeTestResultsTask
        rqmtTask.runsAfter(mergeTestTask);
    end

    % Adds Model Testing Process from Process Automation for Simulink Test Add-On
    if(~isempty(which('pasltest.addProcess')))
        pasltest.addProcess(pm);
    end

end
