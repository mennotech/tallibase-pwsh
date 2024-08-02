$Username = Read-Host "Enter Username (cannot contain colon ':')"
$Password = Read-Host "Enter Password" -AsSecureString |  ConvertFrom-SecureString


"$UserName`n$Password" | Out-File Encrypted-Password.txt -Force
