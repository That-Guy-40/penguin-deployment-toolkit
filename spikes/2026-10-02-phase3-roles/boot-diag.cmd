@echo off
call C:\pdt\id.cmd
set T=C:\pdt\t.txt
> %T% echo === tasks
schtasks /query /tn PDT-boot-event /v /fo list >> %T% 2>&1
schtasks /query /tn PDT-boot-onstart /v /fo list >> %T% 2>&1
>> %T% echo === Kernel-Boot 27
wevtutil qe System /q:"*[System[Provider[@Name='Microsoft-Windows-Kernel-Boot'] and EventID=27]]" /c:5 /f:text /rd:true >> %T% 2>&1
>> %T% echo === task scheduler operational log for PDT-boot-event
wevtutil qe Microsoft-Windows-TaskScheduler/Operational /q:"*[EventData[Data[@Name='TaskName']='\PDT-boot-event']]" /c:10 /f:text /rd:true >> %T% 2>&1
>> %T% echo === powercfg /a
powercfg /a >> %T% 2>&1
>> %T% echo === hiberfil
dir /a C:\hiberfil.sys >> %T% 2>&1
curl.exe -sS -T %T% "%SRV%/uploads/%ID%/%RUN%/tasks.txt" -o nul
call C:\pdt\beacon.cmd diag ok
