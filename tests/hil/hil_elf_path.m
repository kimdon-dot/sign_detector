function p = hil_elf_path(model)
% hil_elf_path  Raspberry Pi에 빌드된 실행 파일 경로 (HilTest가 씀)
%
%   p = hil_elf_path()                 % "~/MATLAB_ws/R2026b/C/Users/.../cache/sign_detector/sign_detector.elf"
%   p = hil_elf_path("sign_detector")
%
% Pi 원격 빌드는 PC의 코드 생성 폴더 경로를 Pi의 ~/MATLAB_ws/R<릴리스>/ 아래에 그대로 옮겨 만든다
% (드라이브 문자의 ':'를 빼고 '\'를 '/'로). 실행 파일은 그 폴더 바로 아래 <모델>.elf.
% 코드 생성 폴더는 프로젝트 설정(Simulink.fileGenControl)에서 읽으므로, 프로젝트가 열려 있어야 함.
% 프로젝트를 옮기거나 다른 PC · 계정에서 빌드해도 이 함수만 보면 됨.
arguments
    model (1, 1) string = "sign_detector"
end
cfg = Simulink.fileGenControl('getConfig');
d = strrep(erase(string(cfg.CodeGenFolder), ":"), "\", "/");
d = regexprep(d, '^/+|/+$', '');
p = "~/MATLAB_ws/R" + version('-release') + "/" + d + "/" + model + ".elf";
end
