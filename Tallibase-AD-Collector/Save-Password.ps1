#Requires -Version 7.0
param (
    [string]$Username = $null,
    [securestring]$Password = $null,
    [Microsoft.Management.Infrastructure.Options.CimCredential]$Credential = $null
)

#Load settings, TODO validate JSON for required configuration fields
try { 
    $Settings = Get-Content "$PSScriptRoot\conf\settings.json" | ConvertFrom-JSON 
}
catch {
    Write-Host "Failed to load $PSScriptRoot\conf\settings.json make sure it is a valid JSON file. Exiting"
    Return 1
}
if (!$Settings) {
    return "Failed to load JSON settings from $PSScriptRoot\conf\settings.json, please rename Settings.Example.json to Settings.json "
}

#Ask for username if not supplied
if (! $Username) {
    $Username = Read-Host "Enter Username (cannot contain colon ':')"
}

#Ask for password if not supplied
if (! $Password) {
    $Password = Read-Host "Enter Password" -AsSecureString
    $EncryptedPassword = $Password | ConvertFrom-SecureString
}


#Write username and password to file
"$UserName`n$EncryptedPassword" | Out-File "$PSScriptRoot\$($Settings.encryptedpasswordfile)" -Force
