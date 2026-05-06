function [Op,S,C,info]=SODAcycle(SE,SOD,COD,IOD,threshold,max_iter,log_every)
% SODACYCLE  Fixed-point SODA solver for cyclic dependency graphs.
%
% Optional args:
%   threshold  convergence tol on max|Oi - Opred|   default 1e-4
%   max_iter   hard cap on outer iterations         default 5000
%   log_every  print residual every K iters (0=off) default 0
%
% info struct: .iter, .residual, .converged. On non-convergence returns
% the last iterate with a warning rather than looping forever.
%
% Original SODA core: Copyright 2012-2016 Cesare Guariniello, Purdue University (v2.1).

if nargin<5 || isempty(threshold)
    threshold=0.0001;
end
if nargin<6 || isempty(max_iter)
    max_iter=5000;
end
if nargin<7 || isempty(log_every)
    log_every=0;
end

Op=0;
S=0;
C=0;
info=struct('iter',0,'residual',NaN,'converged',false);

lambda=0.1;

nodes=size(SOD,1);

if size(SOD,1)~=size(SOD,2)
    error('SODAcycle:SODnotSquare', ...
        'The matrix of Strength of Dependency must be square (got %dx%d)', ...
        size(SOD,1), size(SOD,2))
end

if size(COD,1)~=size(COD,2)
    error('SODAcycle:CODnotSquare', ...
        'The matrix of Criticality of Dependency must be square (got %dx%d)', ...
        size(COD,1), size(COD,2))
end

if max(size(SE,1),size(SE,2))~=size(SOD,1) || size(SOD,1)~=size(COD,1)
    error('SODAcycle:dimMismatch', ...
        ['The length of the Base Operability array (%d) and the size of ', ...
         'the SOD (%dx%d) and COD (%dx%d) matrices must match'], ...
        max(size(SE,1),size(SE,2)), size(SOD,1), size(SOD,2), ...
        size(COD,1), size(COD,2))
end

% IOD must match SOD in size, else the division below silently misindexes.
if size(IOD,1)~=size(SOD,1) || size(IOD,2)~=size(SOD,2)
    error('SODAcycle:IODdimMismatch', ...
        'IOD must be %dx%d to match SOD (got %dx%d)', ...
        size(SOD,1), size(SOD,2), size(IOD,1), size(IOD,2))
end

% IOD must be > 0 on every active edge — otherwise Oi(i)*100/IOD(i,j) below
% produces Inf/NaN and silently corrupts the operability output.
edge_mask = SOD ~= 0;
if any(IOD(edge_mask) <= 0)
    [bi, bj] = find(edge_mask & ~(IOD > 0), 1, 'first');
    error('SODAcycle:IODzero', ...
        ['IOD must be > 0 on every edge where SOD~=0. First offender: ', ...
         'edge (%d,%d) has SOD=%.3f, IOD=%.3f'], ...
        bi, bj, SOD(bi,bj), IOD(bi,bj))
end

Opred=100*ones(1,nodes);
Oi=Opred;

iter=0;
while 1
    iter=iter+1;
    for j=1:nodes
        if nnz(SOD(:,j))==0
            Oi(j)=SE(j);
        else
            pred=0;
            SODP=0;
            CODP=200;
            Oitot=0;
            for i=1:nodes
                if SOD(i,j)~=0
                    pred=pred+1;
                    SODP=SODP+SOD(i,j)*Oi(i)+SE(j)*(1-SOD(i,j));
                    Oitot=Oitot+Oi(i);
                end
            end
            for i=1:nodes
                if SOD(i,j)~=0
                    if pred==1
                        wgt=1;
                    else
                        wgt=(Oitot-Oi(i))/(100*(pred-1));
                    end

                    CODPt=Oi(i)*100/IOD(i,j)+(100-COD(i,j))*wgt^(lambda);
                    if CODPt<CODP
                        CODP=CODPt;
                    end
                end
            end
            SODP=SODP/pred;
            S(j)=SODP;
            C(j)=CODP;
            Oi(j)=min(SODP,CODP);
        end
    end
    residual = max(abs(Opred-Oi));
    if log_every > 0 && (mod(iter, log_every) == 0 || iter == 1)
        fprintf('  SODAcycle iter %d  residual = %.3e\n', iter, residual);
    end
    if residual > threshold
        if iter >= max_iter
            warning('SODAcycle:maxIter', ...
                ['SODAcycle did not converge in %d iterations ', ...
                 '(residual = %.3e, threshold = %.3e). ', ...
                 'Returning last iterate. Try a looser threshold or ', ...
                 'check for tightly-coupled high-SOD cycles.'], ...
                max_iter, residual, threshold);
            Op=Oi;
            info.iter=iter; info.residual=residual; info.converged=false;
            return
        end
        Opred=Oi;
    else
        Op=Oi;
        info.iter=iter; info.residual=residual; info.converged=true;
        break
    end
end


    
