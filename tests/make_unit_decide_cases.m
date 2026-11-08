function make_unit_decide_cases()
% make_unit_decide_cases  unit_decide.xlsx의 시트마다 테스트 케이스를 하나씩 만든다.
%
%   make_unit_decide_cases
%
% - 테스트 파일: tests/unit_decide.mldatx (없으면 새로 만듦), 묶음 이름 'decide'
% - 케이스 이름 = 시트 이름. 같은 이름의 케이스가 이미 있으면 건드리지 않는다.
%   그래서 엑셀에 시트를 추가하고 다시 실행하면 새 케이스만 추가된다.
% - 케이스마다
%     입력      : 그 시트의 Input 열 (열 이름 = 입력포트 이름으로 연결)
%     기대값    : 그 시트의 Output 열 (Baseline)
%     정지 시간 : 그 시트의 마지막 time
%     요구사항  : 시트 이름 앞의 SWRxx -> SWR-xx 에 Verify 링크
% - 테스트 파일 전체: 커버리지 기록 (Decision, Condition, MCDC)

here   = fileparts(mfilename('fullpath'));
root   = fileparts(here);
xlsx   = fullfile(here, 'unit_decide.xlsx');
mldatx = fullfile(here, 'unit_decide.mldatx');
model  = 'unit_decide';
suiteName = 'decide';

% 테스트 파일 열기 (없으면 만들고, 기본으로 생기는 묶음/케이스 정리)
if isfile(mldatx)
    tf = sltest.testmanager.load(mldatx);
else
    tf = sltest.testmanager.TestFile(mldatx);
    ts0 = getTestSuites(tf);
    ts0(1).Name = suiteName;
    remove(getTestCases(ts0(1)));
end

ts = getTestSuites(tf);
ts = ts(strcmp({ts.Name}, suiteName));
if isempty(ts)
    ts = createTestSuite(tf, suiteName);
end

cov = getCoverageSettings(tf);
cov.RecordCoverage = true;
cov.MetricSettings = 'dcm';   % d: Decision, c: Condition, m: MCDC

existing = getTestCases(ts);
existingNames = {};
if ~isempty(existing)
    existingNames = {existing.Name};
end

rs = slreq.load(fullfile(root, 'requirements', 'requirements.slreqx'));

sheets = sheetnames(xlsx);
added = 0;
for k = 1:numel(sheets)
    name = char(sheets(k));
    if ismember(name, existingNames)
        continue
    end

    tc = createTestCase(ts, 'baseline', name);
    setProperty(tc, 'Model', model);

    in = addInput(tc, xlsx, 'Sheets', name, 'CreateIterations', false);
    map(in, 0);   % 0: 입력 열 이름과 입력포트 이름(Block Name)으로 연결

    addBaselineCriteria(tc, xlsx, 'Sheets', name);

    t = readmatrix(xlsx, 'Sheet', name, 'Range', 'A:A');
    setProperty(tc, 'OverrideStopTime', true, 'StopTime', max(t, [], 'omitnan'));

    tok = regexp(name, '^SWR(\d+)_', 'tokens', 'once');
    if isempty(tok)
        warning('요구사항 번호가 없는 시트 이름이라 링크를 건너뜀: %s', name);
    else
        reqId = ['SWR-' tok{1}];
        req = find(rs, 'Type', 'Requirement', 'Id', reqId);
        if isempty(req)
            warning('요구사항을 찾지 못해 링크를 건너뜀: %s (%s)', reqId, name);
        else
            lnk = slreq.createLink(tc, req);
            lnk.Type = 'Verify';
        end
    end

    fprintf('추가: %s\n', name);
    added = added + 1;
end

saveToFile(tf);
lset = slreq.find('type', 'LinkSet', 'Artifact', tf.FilePath);
if ~isempty(lset)
    save(lset);
end
fprintf('완료: %d개 추가, 전체 %d개 (%s)\n', added, numel(getTestCases(ts)), tf.FilePath);
end
