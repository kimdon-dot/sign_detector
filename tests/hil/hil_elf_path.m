function p = hil_elf_path(model)
% Pi에 빌드된 실행 파일 경로: "~/MATLAB_ws/R2026b/C/Users/.../cache/sign_detector/sign_detector.elf"
% Pi는 PC의 코드 생성 폴더 경로(C:\... → C/...)를 ~/MATLAB_ws/R<릴리스>/ 아래에 그대로 만든다.
% 코드 생성 폴더를 프로젝트 설정에서 읽으므로 프로젝트가 열려 있어야 함.
arguments
    model (1, 1) string = "sign_detector"
end
cfg = Simulink.fileGenControl('getConfig');
d = strrep(erase(string(cfg.CodeGenFolder), ":"), "\", "/");
d = regexprep(d, '^/+|/+$', '');
p = "~/MATLAB_ws/R" + version('-release') + "/" + d + "/" + model + ".elf";
end
