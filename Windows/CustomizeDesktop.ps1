# Clear desktop background wallpaper
& reg add "HKCU\Control Panel\Desktop" /v "Wallpaper" /t REG_SZ /d " " /f 
 
# Set static color
& reg add "HKCU\Control Panel\Colors" /v "Background" /t REG_SZ /d "120 120 120" /f 
 
# Disable Dynamic Wallpaper Info Tooltip
& reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v "{2cc5ca98-6485-489a-920e-b3e88a6ccce3}" /t REG_DWORD /d 1 /f 

# Disable Windows Logon Screen Wallpaper
& reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\Background" /v "HideLogonBackgroundImage" /t REG_DWORD /d 1 /f 

# Enable Windows Borders
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name ColorPrevalence -Value 1 -Type DWord
