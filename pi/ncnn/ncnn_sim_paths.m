function s = ncnn_sim_paths(kind)
% PC 시뮬레이션용 NCNN 경로 (unit_recognize의 사용자 지정 코드). 모델 설정에서 '$' 토큰으로 부름:
%   SimUserIncludeDirs : ../pi/ncnn  +  $ncnn_sim_paths('include')$
%   SimUserLibraries   : $ncnn_sim_paths('libs')$
% Windows: cache/ncnn_win/ncnn-20261020-windows-vs2026/x64
% Linux  : cache/ncnn_linux/ncnn-20261020-ubuntu-2404 (+ OpenMP 런타임 libgomp)
% 압축은 직접 받아 풂 (README 빠른 시작 2번). 폴더가 없으면 Simulink가 아래 경로가 없다고 알려 줌
% 코드 생성도 모델을 컴파일하면서 이 경로를 검사하므로 PC용 NCNN이 있어야 함.
% Pi 빌드는 이 경로를 쓰지 않음 (pi_postcodegen이 Pi의 /usr/local/lib/libncnn.a를 링크)
arguments
    kind (1,1) string {mustBeMember(kind, ["include", "libs"])}
end
root = fileparts(fileparts(fileparts(mfilename('fullpath'))));   % sign_detector
libs = ["ncnn", "glslang", "SPIRV", "MachineIndependent", "OSDependent", ...
        "GenericCodeGen", "glslang-default-resource-limits"];
if ispc
    base = fullfile(root, 'cache', 'ncnn_win', 'ncnn-20261020-windows-vs2026', 'x64');
    files = fullfile(base, 'lib', libs + ".lib");
else
    base = fullfile(root, 'cache', 'ncnn_linux', 'ncnn-20261020-ubuntu-2404');
    % 정적 라이브러리는 순서대로 한 번만 훑으므로 쓰는 쪽(ncnn)이 앞, 쓰이는 쪽이 뒤
    files = [fullfile(base, 'lib', "lib" + libs + ".a"), ...
             "/usr/lib/x86_64-linux-gnu/libgomp.so.1"];   % NCNN이 OpenMP를 씀
end
switch kind
    case "include"
        s = fullfile(base, 'include');
    case "libs"
        s = char(strjoin(files, newline));
end
s = char(s);
end
