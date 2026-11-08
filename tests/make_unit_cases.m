function make_unit_cases(xlsx, mldatx, opts)
% make_unit_cases  엑셀 파일의 시트마다 테스트 케이스를 하나씩 만든다 (단위 모델 공통).
%
%   make_unit_cases(xlsx, mldatx)
%   make_unit_cases(xlsx, mldatx, 'Model', 'unit_decide', 'Suite', 'decide')
%
%   예) make_unit_cases('tests/unit_decide.xlsx',      'tests/unit_decide.mldatx')
%       make_unit_cases('tests/unit_can_sender.xlsx',  'tests/unit_can_sender.mldatx')
%
% 입력
%   xlsx   : 테스트 시나리오 엑셀 파일 (시트 하나 = 케이스 하나, '_'로 시작하는 시트는 케이스가 아님)
%   mldatx : 테스트 파일. 없으면 새로 만든다
%   선택 (이름-값)
%     Model        : 테스트할 모델. 기본값은 시트의 'BlockPath: <모델>/<Outport>'에서 읽음
%                    (하네스 이름 '<모델>_Harness1'이면 '_Harness1'을 뗌)
%     Suite        : 테스트 묶음 이름. 기본값은 모델 이름에서 'unit_'을 뗀 것 (unit_decide -> decide)
%     Requirements : 요구사항 세트. 기본값은 <프로젝트>/requirements/requirements.slreqx
%
% - 케이스 이름 = 시트 이름. 같은 이름의 케이스가 이미 있으면 다시 만들지 않는다.
%   그래서 엑셀에 시트를 추가하고 다시 실행하면 새 케이스만 추가된다.
% - 새 케이스마다
%     입력      : 그 시트의 Input 열 (열 이름 = 입력포트 이름으로 연결)
%                 시트에 Input 열이 없으면 <엑셀 이름>_inputs/<시트 이름>.mat (영상처럼 엑셀에 담을 수 없는 입력)
%                 MAT 파일에는 Dataset 변수 하나, 원소 이름 = 입력포트 이름
%                 예) tests/unit_recognize.xlsx 시트 SWR01_class_of_each_sign
%                     -> tests/unit_recognize_inputs/SWR01_class_of_each_sign.mat (원소 rgb)
%     기대값    : 그 시트의 Output 열 (Baseline)
%     정지 시간 : 그 시트의 마지막 time
% - 요구사항 Verify 링크 (새 케이스와 이미 있는 케이스 모두, 이미 걸린 링크는 다시 걸지 않음)
%     시트 이름 앞의 SWRxx -> SWR-xx
%     '_links' 시트가 있으면 그 표의 링크를 더 건다: 열 sheet | requirement (| note, 설명용)
%       예) SWR11_bytes_follow_inputs | SWR-04   (한 시트가 여러 요구사항을 확인할 때 한 줄씩)
%     _links에서 줄을 지워도 이미 걸린 링크는 지우지 않는다 (Test Manager에서 직접 지움)
% - 테스트 파일 전체: 커버리지 기록 (Decision, Condition, MCDC)
% - 모델 고정 스텝이 'auto'면 (최상위 모델 주기를 물려받는 단위) 테스트 파일 Setup/Cleanup 콜백으로
%   테스트 동안만 스텝을 시트의 time 간격으로 바꾼다
arguments
    xlsx {mustBeTextScalar}
    mldatx {mustBeTextScalar}
    opts.Model {mustBeTextScalar} = ''
    opts.Suite {mustBeTextScalar} = ''
    opts.Requirements {mustBeTextScalar} = ''
end

xlsx = absPath(xlsx);
mldatx = absPath(mldatx);
assert(isfile(xlsx), 'make_unit_cases:noExcel', '엑셀 파일이 없습니다: %s', xlsx);
allSheets = sheetnames(xlsx);
sheets = allSheets(~startsWith(allSheets, "_"));
assert(~isempty(sheets), 'make_unit_cases:noSheet', '케이스로 만들 시트가 없습니다: %s', xlsx);

model = char(opts.Model);
if isempty(model)
    model = modelFromSheets(xlsx, sheets);
end
suiteName = char(opts.Suite);
if isempty(suiteName)
    suiteName = regexprep(model, '^unit_', '');
end
reqFile = char(opts.Requirements);
if isempty(reqFile)
    reqFile = fullfile(projectRoot(), 'requirements', 'requirements.slreqx');
end
fprintf('모델: %s, 묶음: %s\n엑셀: %s\n테스트 파일: %s\n', model, suiteName, xlsx, mldatx);

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

setStepCallbacks(tf, model, xlsx, sheets);

existingNames = caseNames(ts);

added = 0;
for k = 1:numel(sheets)
    name = char(sheets(k));
    if ismember(name, existingNames)
        continue
    end

    tc = createTestCase(ts, 'baseline', name);
    setProperty(tc, 'Model', model);

    matIn = inputMatFile(xlsx, name);
    if isempty(matIn)
        in = addInput(tc, xlsx, 'Sheets', name, 'CreateIterations', false);
    else
        in = addInput(tc, matIn, 'CreateIterations', false);   % 엑셀에 담을 수 없는 입력 (영상 등)
    end
    map(in, 0);   % 0: 입력 신호 이름과 입력포트 이름(Block Name)으로 연결

    addBaselineCriteria(tc, xlsx, 'Sheets', name);

    t = readmatrix(xlsx, 'Sheet', name, 'Range', 'A:A');
    setProperty(tc, 'OverrideStopTime', true, 'StopTime', max(t, [], 'omitnan'));

    fprintf('추가: %s\n', name);
    added = added + 1;
end

% 요구사항 링크: 시트 이름 앞 번호 + _links 표
nLinks = 0;
if isfile(reqFile)
    rs = slreq.load(reqFile);
    extra = readLinkTable(xlsx, allSheets);
    cases = getTestCases(ts);
    for tc = cases(:)'
        ids = {};
        tok = regexp(tc.Name, '^SWR(\d+)_', 'tokens', 'once');
        if isempty(tok)
            warning('make_unit_cases:noReqId', '요구사항 번호가 없는 시트 이름: %s', tc.Name);
        else
            ids{end + 1} = ['SWR-' tok{1}]; %#ok<AGROW>
        end
        ids = [ids, extra.requirement(strcmp(extra.sheet, tc.Name))']; %#ok<AGROW>
        for id = unique(ids, 'stable')
            nLinks = nLinks + ensureVerifyLink(rs, tc, id{1});
        end
    end
    unknown = setdiff(extra.sheet, caseNames(ts));
    for u = unknown(:)'
        warning('make_unit_cases:linkSheet', '_links의 시트가 케이스에 없음: %s', u{1});
    end
else
    warning('make_unit_cases:noReq', '요구사항 세트가 없어 링크를 건너뜀: %s', reqFile);
end

saveToFile(tf);
lset = slreq.find('type', 'LinkSet', 'Artifact', tf.FilePath);
if ~isempty(lset)
    save(lset);
end
fprintf('완료: 케이스 %d개 추가 (전체 %d개), 링크 %d개 추가 (%s)\n', ...
    added, numel(getTestCases(ts)), nLinks, tf.FilePath);
end

function setStepCallbacks(tf, model, xlsx, sheets)
% 모델 고정 스텝이 'auto'(최상위 모델 주기를 물려받음)면, 테스트 동안만 시트의 time 간격으로 바꾸는
% Setup/Cleanup 콜백을 테스트 파일에 넣는다. 'auto'가 아니면 건드리지 않음
% 테스트 뒤 모델에 '수정됨' 표시가 남지만, 스텝이 auto로 돌아와 있어 저장해도 내용은 같다
load_system(model);
if ~strcmp(get_param(model, 'FixedStep'), 'auto')
    return
end
t = readmatrix(xlsx, 'Sheet', sheets(1), 'Range', 'A:A');
dt = diff(t(~isnan(t)));
dt = min(dt(dt > 0));
assert(~isempty(dt), 'make_unit_cases:noStep', '시트 %s의 time 열에서 스텝을 알 수 없습니다', sheets(1));
step = sprintf('%.15g', dt);
setProperty(tf, 'SetupCallback', ...
    sprintf("load_system('%s'); set_param('%s', 'FixedStep', '%s');", model, model, step));
setProperty(tf, 'CleanupCallback', sprintf("set_param('%s', 'FixedStep', 'auto');", model));
fprintf('스텝 콜백: %s 고정 스텝 auto -> 테스트 동안 %s\n', model, step);
end

function n = ensureVerifyLink(rs, tc, reqId)
% tc -> reqId Verify 링크가 없으면 건다. 건 개수(0/1)를 돌려줌
n = 0;
req = find(rs, 'Type', 'Requirement', 'Id', reqId);
if isempty(req)
    warning('make_unit_cases:reqNotFound', '요구사항을 찾지 못해 링크를 건너뜀: %s (%s)', reqId, tc.Name);
    return
end
[~, f, e] = fileparts(rs.Filename);
for l = slreq.outLinks(tc)
    d = l.destination();
    if strcmp(l.Type, 'Verify') && isfield(d, 'sid') && d.sid == req.SID && strcmp(d.reqSet, [f e])
        return   % 이미 있음
    end
end
lnk = slreq.createLink(tc, req);
lnk.Type = 'Verify';
fprintf('링크: %s -> %s\n', tc.Name, reqId);
n = 1;
end

function matIn = inputMatFile(xlsx, sheet)
% 시트에 입력 열('Source: Input')이 없으면 <엑셀 이름>_inputs/<시트>.mat을 입력으로 씀. 입력 열이 있으면 ''
c = readcell(xlsx, 'Sheet', sheet, 'Range', '2:2');
c = c(cellfun(@(x) ischar(x) || isstring(x), c));
if any(strcmp(string(c), 'Source: Input'))
    matIn = '';
    return
end
[d, base] = fileparts(xlsx);
matIn = fullfile(d, [base '_inputs'], [sheet '.mat']);
assert(isfile(matIn), 'make_unit_cases:noInput', ...
    '시트 %s에 입력 열이 없고 입력 MAT 파일도 없습니다: %s', sheet, matIn);
end

function t = readLinkTable(xlsx, allSheets)
% '_links' 시트: 1행 머리글 sheet | requirement (| note). 없으면 빈 표
t = struct('sheet', {{}}, 'requirement', {{}});
if ~ismember("_links", allSheets)
    return
end
c = readcell(xlsx, 'Sheet', '_links');
c(cellfun(@(x) isa(x, 'missing'), c)) = {''};
hdr = lower(strtrim(string(c(1, :))));
js = find(hdr == "sheet", 1);
jr = find(hdr == "requirement", 1);
assert(~isempty(js) && ~isempty(jr), 'make_unit_cases:linkHeader', ...
    '_links 시트 1행에 sheet, requirement 머리글이 필요합니다');
for i = 2:size(c, 1)
    s = strtrim(char(string(c{i, js})));
    r = strtrim(char(string(c{i, jr})));
    if isempty(s) || isempty(r), continue, end
    t.sheet{end + 1, 1} = s;
    t.requirement{end + 1, 1} = r;
end
end

function names = caseNames(ts)
c = getTestCases(ts);
names = {};
if ~isempty(c)
    names = {c.Name};
end
end

function model = modelFromSheets(xlsx, sheets)
% 시트의 기대 출력 메타데이터 'BlockPath: <모델>/<Outport>'에서 모델 이름을 읽음
for k = 1:numel(sheets)
    c = readcell(xlsx, 'Sheet', sheets(k), 'Range', '1:6');
    c = c(cellfun(@(x) ischar(x) || isstring(x), c));
    tok = regexp(string(c), '^BlockPath:\s*([^/]+)/', 'tokens', 'once');
    tok = tok(~cellfun(@isempty, tok));
    if ~isempty(tok)
        model = regexprep(char(tok{1}), '_Harness\d+$', '');
        return
    end
end
error('make_unit_cases:noModel', ...
    '시트에서 BlockPath를 찾지 못했습니다. ''Model'' 옵션으로 모델 이름을 지정하세요: %s', xlsx);
end

function root = projectRoot()
% 열린 MATLAB 프로젝트의 루트, 없으면 이 파일의 상위 폴더 (tests/의 부모)
try
    root = char(currentProject().RootFolder);
catch
    root = fileparts(fileparts(mfilename('fullpath')));
end
end

function p = absPath(p)
% 상대 경로는 현재 폴더 기준 절대 경로로
p = char(p);
if isempty(regexp(p, '^([A-Za-z]:[\\/]|[\\/]{2}|/)', 'once'))
    p = fullfile(pwd, p);
end
end
