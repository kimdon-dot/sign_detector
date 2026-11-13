function pi_postcodegen(buildInfo, sources)
% 코드 생성 후 Pi 빌드 정보를 고침. 모델 설정 PostCodeGenCommand에서 보드 기본값 뒤에 붙여 부름:
%   codertarget.postCodeGenHookCommand(h); pi_postcodegen(buildInfo)
% sources: 넣을 C++ 소스. "ncnn" = ncnn_infer.cpp (기본), "can" = 예전 can_tx.cpp (지금은 안 씀)
% 공통: NCNN 정적 링크 + -fopenmp, libcamera 0.7 대응(-std=c++20, libcamera_compat.h)
% 파일은 빌드 폴더로 복사해야 Pi로 같이 넘어감
if nargin < 2
    sources = "ncnn";
end
here = fileparts(mfilename('fullpath')); % pi 폴더
bdir = getLocalBuildDir(buildInfo);
copyfile(fullfile(here, 'libcamera_compat.h'), bdir);
addIncludeFiles(buildInfo, 'libcamera_compat.h', bdir);
% 공유 유틸리티 폴더에는 이 헤더가 안 넘어가서 Pi의 /usr/local/include에도 복사해 둠 (README 실행 방법 > 준비)
for name = string(sources)
    switch name
        case "ncnn"
            add_source(buildInfo, fullfile(here, 'ncnn'), 'ncnn_infer', bdir);
        case "can"
            add_source(buildInfo, fullfile(here, 'can'), 'can_tx', bdir);
        otherwise
            error('pi_postcodegen: 모르는 소스 "%s" (ncnn, can 중 하나)', name);
    end
end
addCompileFlags(buildInfo, '-std=c++20 -include libcamera_compat.h');
addLinkFlags(buildInfo, '-fopenmp'); % NCNN이 OpenMP를 씀 (libgomp)
% 정적 라이브러리는 오브젝트 뒤에 와야 해서, 링크 플래그 대신 오브젝트 뒤에 붙는 MakeVar에 넣음
add_target_libs(buildInfo, '/usr/local/lib/libncnn.a');
end

function add_target_libs(buildInfo, libs)
% rpiutils...addTargetSpecificLibs와 같지만 이 MakeVar가 없을 때도 추가함
name = rpiutils.linux.remotebuild.getBuildInfoMakeVarNameForLinkObjects();
vars = buildInfo.get("MakeVars");
for i = 1:numel(vars)
    if strcmp(vars(i).Key, name)
        if ~contains(vars(i).Value, libs)
            vars(i).Value = [vars(i).Value ' ' libs];
            buildInfo.set("MakeVars", vars);
        end
        return
    end
end
buildInfo.addMakeVars(name, libs);
end

function add_source(buildInfo, src, name, bdir)
% src 폴더의 name.h, name.cpp를 빌드 폴더로 복사해 빌드에 넣음
copyfile(fullfile(src, [name '.h']), bdir);
copyfile(fullfile(src, [name '.cpp']), bdir);
addIncludeFiles(buildInfo, [name '.h'], bdir);
addSourceFiles(buildInfo, [name '.cpp'], bdir);
end
