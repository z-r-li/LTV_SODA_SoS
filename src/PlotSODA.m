
SOD=[0 0.4; 0 0];
COD=[0 80; 0 0];
IOD=[0 100; 0 0];

x=0:1/3:100;
res=zeros(1,size(x,2));
for i=1:size(x,2)
temp=SODA([x(i) 100], SOD, COD, IOD);
res(i)=temp(2);
end

plot(x(1:201),res(1:201),'r','Linewidth',2)
hold on
plot(x(201:size(x,2)),res(201:size(res,2)),'b','Linewidth',2)
xlim([0 100])
ylim([0 100])
xlabel('P_i')
ylabel('P_j')

y=0:5:100;
res2=zeros(1,size(y,2));

for i=1:size(y,2)
temp=SODA([y(i) 100], SOD, COD, IOD);
res2(i)=temp(2);
end

plot(y,res2,'ko')


legend('P_j due to COD','P_j due to SOD','P_j')


plot([x(20) x(55)],[res(20) res(20)],'k')
plot([x(55) x(55)],[res(20) res(55)],'k')


plot([x(221) x(281)],[res(221) res(221)],'k')
plot([x(281) x(281)],[res(221) res(281)],'k')
