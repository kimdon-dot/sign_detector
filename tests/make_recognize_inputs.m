function make_recognize_inputs(xlsx, opts)
% make_recognize_inputs  엑셀의 '_frames' 시트(사진 목록)로 unit_recognize 테스트 입력 MAT 파일을 만든다.
%
%   make_recognize_inputs
%   make_recognize_inputs('tests/unit_recognize.xlsx', 'ImageDir', 'D:/photos/raw')
%   make_recognize_inputs(..., 'Sheets', "SWR01_class_of_each_sign")
%
% '_frames' 시트 (1행 머리글)
%   sheet | step | time | image | expected_cls
%   - sheet       : 테스트 시트 이름 (= 케이스 이름, MAT 파일 이름)
%   - step, time  : 프레임 순서와 시뮬레이션 시각 (time은 그 시트의 time 열과 같아야 함)
%   - image       : ImageDir 기준 사진 경로 (예: capture_30/000.jpg), 480x640 RGB
%   - expected_cls: 기대 클래스 (그 시트에 cls 열이 있으면 같아야 함, 다르면 오류. 없으면 설명용)
%
% 단위 모델(unit_recognize.xlsx): 한 행 = 한 프레임, time/cls를 시트와 대조
% 최상위 모델(sign_detector.xlsx): 사진이 바뀌는 시각에만 한 줄. 입력포트 rgb의 '데이터 보간'이 꺼져 있어
%   다음 사진까지 같은 사진이 유지됨. 시트의 기대값은 send/data라 대조하지 않음
%   주의: 마지막 줄 시각 뒤로는 입력이 0(검은 화면)이 되므로, 정지 시각에 마지막 사진을 한 줄 더 둔다
%
% 결과: <엑셀 폴더>/<엑셀 이름>_inputs/<sheet>.mat
%   변수 inputs = Simulink.SimulationData.Dataset, 원소 timeseries 'rgb' (480x640x3xN uint8)
%   make_unit_cases가 시트에 입력 열이 없을 때 이 파일을 입력으로 씀
% 내용이 같은 파일은 다시 쓰지 않음 (git에 바뀐 것으로 보이지 않게)
%
% 순서: 사진/_frames 수정 -> make_recognize_inputs -> (새 시트면) make_unit_cases
arguments
    xlsx {mustBeTextScalar} = fullfile(fileparts(mfilename('fullpath')), 'unit_recognize.xlsx')
    opts.ImageDir {mustBeTextScalar} = defaultImageDir()
    opts.Sheets string = string.empty
end

xlsx = char(xlsx);
assert(isfile(xlsx), 'make_recognize_inputs:noExcel', '엑셀 파일이 없습니다: %s', xlsx);
imageDir = char(opts.ImageDir);
assert(isfolder(imageDir), 'make_recognize_inputs:noImageDir', ...
    '사진 폴더가 없습니다: %s\n(''ImageDir'' 옵션으로 지정하세요)', imageDir);

frames = readtable(xlsx, 'Sheet', '_frames', 'TextType', 'string');
frames = sortrows(frames, {'sheet', 'step'});
sheets = unique(frames.sheet, 'stable');
if ~isempty(opts.Sheets)
    missing = setdiff(opts.Sheets, sheets);
    assert(isempty(missing), 'make_recognize_inputs:noSheet', ...
        '_frames에 없는 시트: %s', strjoin(missing, ', '));
    sheets = opts.Sheets(:);
end

[d, base] = fileparts(xlsx);
outDir = fullfile(d, [base '_inputs']);
if ~isfolder(outDir)
    mkdir(outDir);
end

written = 0;
for k = 1:numel(sheets)
    name = sheets(k);
    f = frames(frames.sheet == name, :);
    checkAgainstSheet(xlsx, name, f);

    n = height(f);
    rgb = zeros(480, 640, 3, n, 'uint8');
    for j = 1:n
        file = fullfile(imageDir, f.image(j));
        img = imread(file);
        assert(isequal(size(img), [480 640 3]) && isa(img, 'uint8'), 'make_recognize_inputs:badImage', ...
            '사진이 480x640x3 uint8이 아닙니다: %s (%s)', file, mat2str(size(img)));
        rgb(:, :, :, j) = img;
    end

    ts = timeseries(rgb, f.time(:), 'Name', 'rgb');
    inputs = Simulink.SimulationData.Dataset;
    inputs = addElement(inputs, ts);

    matFile = fullfile(outDir, name + ".mat");
    if isfile(matFile) && sameContent(matFile, ts)
        fprintf('그대로: %s (%d장)\n', name, n);
        continue
    end
    save(matFile, 'inputs');
    fprintf('만듦: %s (%d장) -> %s\n', name, n, matFile);
    written = written + 1;
end
fprintf('완료: %d개 파일 씀, %d개 그대로\n', written, numel(sheets) - written);
end

function checkAgainstSheet(xlsx, name, f)
% _frames의 time, expected_cls가 테스트 시트의 time, cls 열과 같은지 확인
% - 시트가 아직 없으면 건너뜀 (입력을 먼저 만들고 기대값 시트를 나중에 만드는 경우)
% - 시트에 cls 열이 없으면 건너뜀 (최상위 모델 시트: 사진은 바뀌는 시각에만 두고 입력포트가 다음 사진까지 유지,
%   기대값은 send/data라 프레임과 1:1이 아님)
if ~ismember(name, sheetnames(xlsx))
    fprintf('  (시트 %s가 아직 없어 대조를 건너뜀)\n', name);
    return
end
c = readcell(xlsx, 'Sheet', name);
head = string(c(1, :));
tCol = find(head == "time", 1);
cCol = find(head == "cls", 1);
if isempty(cCol)
    return
end
assert(~isempty(tCol), 'make_recognize_inputs:badSheet', '시트 %s의 1행에 time 열이 없습니다', name);
isNum = cellfun(@(x) isnumeric(x) && isscalar(x) && ~ismissing(x), c(:, tCol));
t = cell2mat(c(isNum, tCol));
cls = cell2mat(c(isNum, cCol));
assert(isequal(t(:), f.time(:)), 'make_recognize_inputs:timeMismatch', ...
    '시트 %s: time 열 %s와 _frames의 time %s가 다릅니다', name, mat2str(t'), mat2str(f.time'));
assert(isequal(cls(:), f.expected_cls(:)), 'make_recognize_inputs:clsMismatch', ...
    '시트 %s: cls 열 %s와 _frames의 expected_cls %s가 다릅니다', name, mat2str(cls'), mat2str(f.expected_cls'));
end

function tf = sameContent(matFile, ts)
tf = false;
try
    s = load(matFile, 'inputs');
    old = s.inputs{1};
    tf = isa(old, 'timeseries') && strcmp(old.Name, ts.Name) && ...
        isequal(old.Time, ts.Time) && isequal(old.Data, ts.Data);
catch
end
end

function p = defaultImageDir()
% <프로젝트 상위 폴더>/cache/dataset/raw (프로젝트 밖, 다른 외부 파일과 같은 곳)
root = fileparts(fileparts(mfilename('fullpath')));   % sign_detector
p = fullfile(fileparts(root), 'cache', 'dataset', 'raw');
end
