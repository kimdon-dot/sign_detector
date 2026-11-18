function [ev, out] = runPiScript(name)
% Pi에서 시나리오 스크립트 ~/hil/<name>.sh 실행
% 원본은 tests/hil/pi/<name>.sh (HilTest가 시작할 때 Pi에 올림)
%   ev  : 스크립트가 찍은 "@이름 값" 줄 → ev.이름 (숫자)
%   out : 그 밖의 출력
[status, out] = runOnPi("bash ~/hil/" + name + ".sh");
if status ~= 0
    error('%s.sh 실행 실패 (종료 코드 %d): %s', name, status, out);
end

ev = struct();
for t = regexp(out, '^@(\w+) (\S+)', 'tokens', 'lineanchors')
    ev.(t{1}{1}) = str2double(t{1}{2});
end
out = strtrim(regexprep(out, '^@\w+ \S+\r?\n?', '', 'lineanchors'));
end
