function pi_postcodegen(buildInfo, sources)
%PI_POSTCODEGEN 코드 생성 후 Pi 빌드 정보를 고침 (모델 설정 PostCodeGenCommand에서 부름)
% PostCodeGenCommand는 보드 기본값 뒤에 붙여야 함 (지우면 Pi 시작 코드가 빠져 MW_raspi_init.h 오류):
%   unit_recognize: codertarget.postCodeGenHookCommand(h); pi_postcodegen(buildInfo)
%   sources: 이 모델 빌드에 넣을 C++ 소스 (기본 "ncnn")
%     "ncnn": pi/ncnn/ncnn_infer.cpp (unit_recognize의 Infer/NCNN Infer 블록이 coder.ceval로 부름)
%     "can":  예전 프로젝트의 pi/can/can_tx.cpp용. 지금 프로젝트는 CAN을 Raspberry Pi CAN Transmit 블록으로 보내서 쓰지 않음
%     최상위 모델이 unit_recognize를 참조할 때 "ncnn"을 다시 넣지 않음: ncnn_infer.cpp는 참조 모델 라이브러리에 이미 들어감
% 모든 모델에 공통으로 넣는 것
% 1) NCNN 링크: Pi의 /usr/local/lib/libncnn.a, -fopenmp (최상위 실행 파일 링크에 필요, Pi 준비는 pi/ncnn/README.md)
% 2) Pi 카메라 블록과 Pi의 libcamera 0.7(Debian 13)을 맞춤
%    카메라 블록이 -std=c++17과 없어진 libcamera::Span을 씀 -> -std=c++20, pi/libcamera_compat.h를 모든 소스 앞에 넣음
% 파일은 빌드 폴더로 복사해야 Pi로 같이 넘어감
if nargin < 2
    sources = "ncnn";
end
here = fileparts(mfilename('fullpath')); % pi 폴더
bdir = getLocalBuildDir(buildInfo);
copyfile(fullfile(here, 'libcamera_compat.h'), bdir);
addIncludeFiles(buildInfo, 'libcamera_compat.h', bdir);
% 주의: 공유 유틸리티(slprj/ert/_sharedutils)는 최상위 모델 빌드에서 같은 -include 옵션으로 다시 컴파일되지만,
%       그 폴더에는 이 헤더가 Pi로 전달되지 않음 -> Pi의 /usr/local/include에도 설치해 둠 (pi/ncnn/README.md Pi 준비 3)
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
% 정적 라이브러리는 오브젝트 뒤에 와야 함: 링크 플래그(LDFLAGS)는 오브젝트 앞에 오고 addSysLibs는 -l을 안 넣으므로,
% 카메라 블록(-lcamera 등)처럼 Pi 빌드가 오브젝트 뒤(LIBS)에 붙이는 MakeVar LINUX_TARGET_CUSTOM_LIBS에 넣음
% (make가 이 목록을 전제 조건으로 찾으므로 -lgomp처럼 gcc 내부 폴더에 있는 것은 넣지 않음)
add_target_libs(buildInfo, '/usr/local/lib/libncnn.a');
end

function add_target_libs(buildInfo, libs)
% rpiutils.linux.remotebuild.addTargetSpecificLibs와 같지만, 다른 MakeVar만 있고 이 변수가 없을 때도 추가함
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
