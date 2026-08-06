CD "C:\Users\apedone\Downloads\DISKSPD\amd64"
diskspd.exe -b8K -d60 -o32 -t8 -r -w30 -h -L -c20G F:\Data\DiskSpd_Test.dat > Data-DiskSpd-Test-Results.txt
diskspd.exe -b64K -d60 -o8 -t2 -w100 -h -L -c20G F:\Logs\DiskSpd_Log_Test.dat > Log-DiskSpd-Test-Results.txt
diskspd.exe -b64K -d60 -o32 -t8 -r -w50 -h -L -c20G F:\TempDB\DiskSpd_TempDB.dat > TempDB-DiskSpd-Test-Results.txt
diskspd.exe -b256K -d60 -o16 -t8 -w100 -h -L -c20G F:\Data\DiskSpd_BulkLoad.dat > Data-BulkLoad-DiskSpd-Test-Results.txt
diskspd.exe -b64K -d60 -o1 -t1 -w100 -h -L -c20G F:\Logs\DiskSpd_Log_QD1.dat > DiskSpd_Log_QD1.txt
diskspd.exe -b64K -d60 -o2 -t1 -w100 -h -L -c20G F:\Logs\DiskSpd_Log_QD2.dat > DiskSpd_Log_QD2.txt
