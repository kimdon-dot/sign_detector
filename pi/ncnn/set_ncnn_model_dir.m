% SET_NCNN_MODEL_DIR 프로젝트를 열 때 자동 실행 (프로젝트 시작 파일)
% PC 시뮬레이션에서 unit_recognize의 NCNN 추론(pi/ncnn/ncnn_infer.cpp)이 모델 파일을 찾는 폴더를 정함
%   환경 변수 NCNN_INFER_MODEL_DIR = <프로젝트 상위 폴더>/cache/best_ncnn_model
%   (model.ncnn.param/.bin, imgsz 480x640. Pi의 /home/pi/sign_detector_project/best_ncnn_model과 같은 파일)
% 이미 설정되어 있으면 바꾸지 않음 (다른 모델 폴더를 쓰려면 MATLAB에서 setenv 후 시뮬레이션)
% Pi에서는 이 변수가 없어서 ncnn_infer.cpp의 기본 경로를 씀
if isempty(getenv('NCNN_INFER_MODEL_DIR'))
    root = fileparts(fileparts(fileparts(mfilename('fullpath'))));   % sign_detector
    setenv('NCNN_INFER_MODEL_DIR', fullfile(fileparts(root), 'cache', 'best_ncnn_model'));
end
if ~isfile(fullfile(getenv('NCNN_INFER_MODEL_DIR'), 'model.ncnn.param'))
    warning('set_ncnn_model_dir:noModel', 'NCNN 모델 파일이 없습니다: %s', getenv('NCNN_INFER_MODEL_DIR'));
end
