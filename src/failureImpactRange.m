function failureImpactRange(SOD, COD, IOD, low_range, high_range, cluster_max, plots, plot_limit, resolution, labels, fnodes)

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% failureImpactRange(SOD, COD, IOD, low_range, high_range, cluster_max, plots, plot_limit, resolution, labels,fnodes)
%   Function to characterize the impact of failures on operability range with deterministic SODA
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% Mandatory arguments:
% SOD: matrix of Strength of Dependency (SODA model)
% COD: matrix of Criticality of Dependency (SODA model)
% IOD: matrix of Impact of Dependency (SODA model)
%
% Optional arguments:
% low_range: maximum value of range of low operability. Default: 25
% high_range: minimum value of range of high operability. Default: 75
%       0 <= low operability <= low_range < medium operability < high_range <= high operability <= 100
% cluster_max: size of the largest subset of failed nodes to analyze. Default: 3
% plots: type of plots. 1 = only plots by size of failed subset. 2 = only general plot,
%                       including all subsets. 3 = both type of plots. Default: 3
% plot_limit: number of ranked failed subsets to show in the plot. Default: 10
% resolution: resolution of Self-Effectiveness. Default: 1
% labels: cell array of strings containing the names of nodes
% fnodes: list of indeces of "final nodes"

tic
if nargin > 10
    fnodes_flag=1;
else
    fnodes_flag=0;
end

if nargin > 9 && ~isempty(labels) && numel(labels) == size(SOD,1)
    % Normalize labels to a row of chars (callers may pass rows or columns,
    % chars or strings).
    labels = labels(:).';
    for k = 1:numel(labels)
        if isstring(labels{k}); labels{k} = char(labels{k}); end
    end
    labels_flag = 1;
    for k = 1:numel(labels)-1
        labels{k}=[labels{k} ' '];
    end
else
    labels_flag = 0;
end

if nargin < 9
    resolution = 1;
end
if nargin < 8
    plot_limit = 10;
end
if nargin < 7
    plots = 3;
end
if nargin < 6
    cluster_max = 3;
end
if nargin < 5
    high_range = 75;
end
if nargin < 4
    low_range = 25;
end

if low_range < 0
    low_range = 0;
end

if high_range > 100
    high_range = 100;
end

if low_range > high_range
    swap = low_range;
    low_range = high_range;
    high_range = swap;
end


n = size(SOD,1); % number of nodes
if cluster_max > n
    cluster_max = n;
end
if fnodes_flag==0
    fnodes = find(ismember(SOD,zeros(1,n),'rows')); % array of indeces of final nodes
end

if isempty(fnodes)
    disp('The network does not have leaf nodes');
    return
end

gr = digraph(SOD);
if isdag(gr)
    cyclic_flag = 0;
else
    cyclic_flag = 1;
end

if rem(100, resolution) == 0
    SE_fail = 0:resolution:100;
else
    SE_fail = [0:resolution:100, 100];
end

res = cell(1,cluster_max); % create cell array of results
sortres = cell(1,cluster_max);
for i = 1:cluster_max
    fprintf('\n Sets of %d nodes \n',i);
    index = setdiff(1:n,fnodes);
    clusters = nchoosek(index,i);   % all subsets of size i (was combnk in original)
    fprintf('Found %d sets of %d nodes \n',size(clusters,1),i);
    res{i} = cell(size(clusters,1),4);
    sortres{i} = cell(size(clusters,1),4);
    flag = 10;
    for j = 1:size(clusters,1)
        if 100*j/size(clusters,1) >= flag
            fprintf('%d%% of the sets of %d nodes complete \n',round(100*j/size(clusters,1),-1),i);
            flag=round(100*j/size(clusters,1),-1)+10;
        end
        res{i}{j,1} = clusters(j,:);
        res{i}{j,2} = zeros(1,size(SE_fail,2));
        for k = 1:size(SE_fail,2)
            SE = 100*ones(1,n); % sets all the nodes at 100
            SE(clusters(j,:)) = SE_fail(k); % sets the nodes in the failed cluster at failed_utils
            if cyclic_flag == 0
                oper = SODA(SE,SOD,COD,IOD);
            else
                oper = SODAcycle(SE,SOD,COD,IOD);
            end
            %res{i}{j,2}(k) = mean(oper(fnodes));
            res{i}{j,2}(k) = min(oper(fnodes));
        end
        res{i}{j,3} = nnz(res{i}{j,2}(:) > low_range);
        res{i}{j,4} = nnz(res{i}{j,2}(:) >= high_range);
    end
    sortres{i}=sortrows(res{i},[3 4]);
end

if plots == 2 || plots == 3 % put all the results in a single array
    resall = res{1};
    for i = 2:cluster_max
        resall=[resall;res{i}];
    end
    sortresall=sortrows(resall,[3 4]);
end

% PLOTS

if plots == 1 || plots == 3
    for i = 1:cluster_max
        figure(i)
        set(gcf, 'Position', [40+10*(i) 60+8*(i) 1200 600])
        names = {sortres{i}{1:min(plot_limit,size(sortres{i},1)),1}};
        lists = num2str(cell2mat(names'));
        str = cell(1,size(lists,1));
        for k = 1:size(lists,1)
            if labels_flag == 0
            	str{k} = sprintf('[%s]',lists(k,:));
            else
                str{k} = strcat('[', cell2mat(labels(names{k})), ']');
            end
        end
        tempdata = cell2mat(sortres{i}(1:min(plot_limit,size(sortres{i},1)),3:4));
        data = [resolution*( max( ((size(SE_fail,2)-1)*ones(size(tempdata,1),1)) - tempdata(:,1), zeros(size(tempdata,1),1)) ), ...
            resolution*( min( (tempdata(:,1) - tempdata(:,2)), ((size(SE_fail,2)-1)*ones(size(tempdata,1),1)) ))];
        data(:,3)=100*ones(size(data,1),1)-data(:,1)-data(:,2);
        b=bar(data,'stacked'); % shows average LOSS of utils of end nodes
        b(1).FaceColor='red';
        b(2).FaceColor='yellow';
        b(3).FaceColor='green';
        legend(sprintf('Average operability of end nodes LOW (Op <= %.0f)',low_range), sprintf('Average operability of end nodes MEDIUM (%.0f < Op < %.0f)',low_range,high_range),...
            sprintf('Average operability of end nodes HIGH (%.0f <= Op)',high_range));
        set(gca,'XTick',1:min(plot_limit,size(sortres{i},1)))
        set(gca,'XTickLabel',str)
        xtickangle(45)
        title(sprintf('Impact of failure in sets of %d nodes (out of %d) on operability of end nodes',i,n));
        ylabel('Self-Effectiveness of nodes in the set');
        xlabel(sprintf('Sets of %d nodes (ranked by decreasing criticality)',i));
        grid on
    end
end

if plots == 2 || plots == 3
    figure(cluster_max+1)
    set(gcf, 'Position', [40+10*(cluster_max+1) 60+8*(cluster_max+1) 1200 600])
    names = {sortresall{1:min(plot_limit,size(sortresall,1)),1}};
    str = cell(1,size(names,2));
    for k = 1:size(names,2)
        if labels_flag == 0
            str{k} = sprintf('[%s]',num2str(names{k}));
        else
            str{k} = strcat('[', cell2mat(labels(names{k})), ']');
        end
    end
    tempdata = cell2mat(sortresall(1:min(plot_limit,size(sortresall,1)),3:4));
    data = [resolution*( max( ((size(SE_fail,2)-1)*ones(size(tempdata,1),1)) - tempdata(:,1), zeros(size(tempdata,1),1)) ), ...
            resolution*( min( (tempdata(:,1) - tempdata(:,2)), ((size(SE_fail,2)-1)*ones(size(tempdata,1),1)) ))];
    data(:,3)=100*ones(size(data,1),1)-data(:,1)-data(:,2);
    b=bar(data,'stacked'); % shows average LOSS of utils of end nodes
    b(1).FaceColor='red';
    b(2).FaceColor='yellow';
    b(3).FaceColor='green';
    legend(sprintf('Average operability of end nodes LOW (Op <= %.0f)',low_range), sprintf('Average operability of end nodes MEDIUM (%.0f < Op < %.0f)',low_range,high_range),...
        sprintf('Average operability of end nodes HIGH (%.0f <= Op)',high_range));
    set(gca,'XTick',1:min(plot_limit,size(sortresall,1)))
    set(gca,'XTickLabel',str)
    xtickangle(45)
    title(sprintf('Impact of failure in sets with size ranging from 1 node to %d nodes on operability of end nodes',min(cluster_max,n)));
    ylabel('Self-Effectiveness of nodes in the set');
    xlabel('Sets of nodes (ranked by decreasing criticality)');
    grid on
end

t=toc;
fprintf('\nTime required for analysis of node subsets of size 1 to %d in a network of %d nodes: %.1f seconds \n', cluster_max, n, t);

assignin('base','res',res);
assignin('base','sortres',sortres);
if plots == 2 || plots == 3
    assignin('base','resall',resall);
    assignin('base','sortresall',sortresall);
end
