function [status, out] = runOnPi(remoteCmd)
    sshCmd = ['ssh -o BatchMode=yes -o ConnectTimeout=5 pi "' char(remoteCmd) '"'];
    for attempt = 1:3
        [status, out] = system(sshCmd);
        if status ~= 255, break; end   % 255 = ssh 접속 자체가 실패 (이름 찾기 · 연결) → 다시 시도
        pause(1);
    end
    out = strtrim(out);
end
