% 프로젝트를 열 때 자동 실행: PC 시뮬레이션의 NCNN 모델 폴더를 정함
%   NCNN_INFER_MODEL_DIR = <프로젝트>/cache/best_ncnn_model (이미 설정되어 있으면 그대로)
% Pi에서는 ncnn_infer.cpp의 기본 경로를 씀
if isempty(getenv('NCNN_INFER_MODEL_DIR'))
    root = fileparts(fileparts(fileparts(mfilename('fullpath'))));   % sign_detector
    setenv('NCNN_INFER_MODEL_DIR', fullfile(root, 'cache', 'best_ncnn_model'));
end
if ~isfile(fullfile(getenv('NCNN_INFER_MODEL_DIR'), 'model.ncnn.param'))
    warning('set_ncnn_model_dir:noModel', 'NCNN 모델 파일이 없습니다: %s', getenv('NCNN_INFER_MODEL_DIR'));
end
