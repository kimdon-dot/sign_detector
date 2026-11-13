function [status, out] = runOnPi(remoteCmd)
    sshCmd = ['ssh -o BatchMode=yes -o ConnectTimeout=5 pi "' char(remoteCmd) '"'];
    [status, out] = system(sshCmd);
    out = strtrim(out);
end
