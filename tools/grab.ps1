Start-Sleep -Seconds 5
$tern = "$env:LOCALAPPDATA/Programs/Tern/tern.exe"
& $tern capture toons.cartoon --ansi --surfaces *> 'C:/Users/lalal/AppData/Local/Temp/cartoon_capture.txt'
& $tern ls --json *> 'C:/Users/lalal/AppData/Local/Temp/cartoon_ls.json'
