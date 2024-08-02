#Requires -Version 7.0
param (
    [bool]$RESTTest = $false
)


#Set logfile path and initial debug level
$script:logfile = "$PSScriptRoot\log\$((Get-Date).ToString('yyyy-MM'))-Invoke-TallibaseDeviceSearch.log"
$script:loglevel = 7

#Log levels
# 1 - Emergency
# 2 - Alert
# 3 - Critical
# 4 - Error
# 5 - Warning
# 6 - Notice
# 7 - Information
# 8 - Debug

function Init {

    #Load settings, TODO validate JSON for required configuration fields
    try { 
        $script:settings = Get-Content "$PSScriptRoot\conf\settings.json" | ConvertFrom-JSON 
    }
    catch {
        Write-Log -Level 1 -Text "Failed to load $PSScriptRoot\conf\settings.json make sure it is a valid JSON file. Exiting"
        exit 1
    }
    if (!$script:settings) {
        Write-Log -Level 1 -Text "Failed to load JSON settings from $PSScriptRoot\conf\settings.json, please rename Settings.Example.json to Settings.json "
        exit 1
    }

    #Parse settings and apply to variables
    $script:SiteURL = $script:settings.server
    if ($script:settings.loglevel) { $script:loglevel = $script:settings.loglevel}

    #Exit if password file doesn't exist
    if (!(Test-Path -Path "$PSScriptRoot\$($script:settings.encryptedpasswordfile)" )) {
        Write-Log -Level 1 -Text  "Failed to find password file $PSScriptRoot\$($script:settings.encryptedpasswordfile)"
        Write-Log -Level 1 -Text  "Please run Save-Password.ps1 to create"
        exit 2
    }

    #Read encrypted password
    $Username,$Password = Get-Content "$PSScriptRoot\$($script:settings.encryptedpasswordfile)"
    if (!($Username -AND $Password)) {
        Write-Log -Level 1 -Text "Failed to load username and password"
        exit 3
    }

    #Create Authentication Headers
    $Password = $Password | ConvertTo-SecureString
    $Pair = "$($Username):$([System.Net.NetworkCredential]::new('', $Password).Password)"
    $EncodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $script:headers = @{ Authorization = "Basic $EncodedCreds"; 'Content-Type' = "application/json" };
}

function Main {
    
    #Stop on all unhandled errors
    trap [Exception] {
        Write-Log -Level 1 -Text "Exception Error at Line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"   
        $ErrorMessage = $_.Exception.Message -replace "`r|`n"," "
        Write-Log -Level 1 -Text "Fatal Error Message: $ErrorMessage"
        exit 101
    }

    #Run Init function
    Init
  
    #Run Tests if specified end exit
    if ($RESTTest) {
        return Invoke-RESTTest
    }

    Write-Log -Level 6 -Text "Searching for ADObjects in $($script:settings.devices.searchBase)"
    $DeviceADObjects = Get-ADObject -SearchBase $script:settings.devices.searchBase -Filter $script:settings.devices.searchFilter | Where-Object ObjectClass -eq 'computer'

    if (!$DeviceADObjects) {
        return "No Objects found"
    }
    Write-Log -Level 6 -Text "Pinging device list to see which are online devices..."
    $OnlineDevices = Test-ComputerConnections -ComputerNames $DeviceADObjects.Name


    Write-Log -Level 6 -Text "Connecting to online devices to get asset info..."
    $AssetInfo = @()
    foreach ($Device in $OnlineDevices) {
        $AssetInfo += Get-AssetInfo -DeviceName $Device
    }

    Update-TallibaseDevices -Devices $AssetInfo

}

<#
    Attempt to import the example data into the website
#>
function Invoke-RESTTest {
    
        Write-Log -Level 6 -Text  "Running simple REST Test with $($script:SiteURL)"
        $ContentTypes = @('device_models','vendors','devices')
        
        foreach ($ContentType in $ContentTypes) {
            if (Test-Path "$PSScriptRoot\examples\$ContentType.json") {
                Write-Log -Level 7 -Text "Loading $PSScriptRoot\examples\$ContentType.json"
                [array]$Resources = Get-Content "$PSScriptRoot\examples\$ContentType.json" | ConvertFrom-Json
            }
            foreach ($Resource in $Resources) {
                #TODO check if the node already exists using the uuid
                Write-Log -Level 6 -Text "Creating new $ContentType : $($Resource | ConvertTo-Json -Compress -Depth 10)"
                try {
                    $null = Invoke-RestMethod -Method POST -Uri "$SiteURL/node?_format=json" -Body ($Resource | ConvertTo-Json -Depth 10) -Headers $Headers
                }
                catch {
                    Write-Log -Level 4 -Text "ERROR REST Method failed with StatusCode: $($_.Exception.Response.StatusCode.value__) $($_.Exception.Response.ReasonPhrase) - $($_.Exception.Response.StatusDescription)"
                }
            }
        }
    
        #Get list of devices
        $Devices = Invoke-RestMethod -Uri "$($script:SiteURL)/views/devices?_format=json" -Headers $headers
        Get-SimplifiedDrupalObject $Devices | Format-Table title, nid, uuid
        return
    }

function Update-TallibaseDevices {
    Param(
        $Devices
    )
    
    Write-Log -Level 6 -Text "Updating Tallibase Database..."
    
    $WebDevices = Invoke-DrupalResource -Path "views/devices"

    foreach ($Device in $Devices) {
        if ($Device.SerialNumber -in $WebDevices.field_serial_number) {
            $WebDevice = $WebDevices | Where-Object field_serial_number -eq $Devices.SerialNumber
            if (($WebDevice).count -eq 1) {
                $null = Update-TallibaseDevice -AssetInfo $Device -UUID $WebDevice
            }
        } else {
            $null = New-TallibaseDevice -AssetInfo $Device
        }
    }

}


function Get-TallibaseFieldOptions {
    Param(
        $Vendors = $true,
        $DeviceModels = $true
    )
    if ($Vendors -and !$script:TallibaseVendors) { 
        [array]$script:TallibaseVendors = Invoke-DrupalResource -Path "vendor" 
    }
    
    if ($DeviceModels -and !$script:TallibaseDeviceModels) {
        [array]$script:TallibaseDeviceModels = Invoke-DrupalResource -Path "device_model"
    }
}

function New-TallibaseDevice {
    Param(
        $AssetInfo = $null
    )
    
    #Load field options if needed
    Get-TallibaseFieldOptions
    
    if ($AssetInfo) {
        Write-Log -Level 6 -Text "Creating new TalliBase device $AssetInfo"
        
        $TalliBaseResource = [PSCustomObject]@{
            type = "device"
            title = $AssetInfo.DeviceName
            field_device_model = Get-TalliBaseFieldID -FieldName 'field_device_model' -Value $AssetInfo.Model
            field_serial_number = $AssetInfo.SerialNumber
            field_manufacturer = Get-TalliBaseFieldID -FieldName 'field_manufacturer' -Value $AssetInfo.Manufacturer
        }
        
        return Invoke-DrupalResource -Path "node" -Method "POST" -Body $TalliBaseResource
    }

}
	
function Get-TalliBaseFieldID {
    Param(
        [string]$FieldName = (raise "Provided a FieldName"),
        $Value = (raise "Provided a Value")
    )
    #TODO fix this to make it more dynamic
    Get-TallibaseFieldOptions
    switch ($FieldName) {
        "field_device_model" {
            if ($Value -in $script:TallibaseDeviceModels.title) {
                return [PSCustomObject]@{
                    target_id = [string]($script:TallibaseDeviceModels | Where-Object title -eq $Value).nid
                }
            }
            else {
                Write-Log -Level 6 -Text "Did not find $FieldName with value $Value, creating"
                $TalliBaseResource = [PSCustomObject]@{
                    type = "device_model"
                    title = $Value
                }
                $NewResource = Invoke-DrupalResource -Path "node" -Method "POST" -Body $TalliBaseResource
                #Update vendors
                if ($NewResource) {
                    $script:TallibaseDeviceModels += $NewResource
                    return [PSCustomObject]@{
                        target_id = [string]$NewResource.nid
                    }
                } else {
                    return $false
                }
            }
        }
        "field_manufacturer" {
            if ($Value -in $script:TallibaseVendors.title) {
                return [PSCustomObject]@{
                    target_id = [string]($script:TallibaseVendors | Where-Object title -eq $Value).nid
                }
            }
            else {
                Write-Log -Level 6 -Text "Did not find $FieldName with value $Value, creating"
                $TalliBaseResource = [PSCustomObject]@{
                    type = "vendor"
                    title = $Value
                }
                $NewResource = Invoke-DrupalResource -Path "node" -Method "POST" -Body $TalliBaseResource
                #Update vendors
                if ($NewResource) {
                    $script:TallibaseVendors += $NewResource
                    return [PSCustomObject]@{
                        target_id = [string]$NewResource.nid
                    }
                } else {
                    return $false
                }
            }
        }
    }

}
function Invoke-DrupalResource {
    Param(
        $Path,
        $Method = "GET",
        $Simplify = $true,
        $RAWBody = $false,
        $Headers = $script:headers,
        $Body = $null
    )

    if ($Body -and ! $RAWBody) {
        try {
            $Body = ConvertTo-DrupalResource -Object $Body
            $Body = ConvertTo-Json -Compress -Depth 5 -InputObject $Body
            Write-Log -Level 8 -Text "POST body: $body"
        }
        catch {
            Write-Log -Level 3 -Text "Get-DrupalResource: Failed to convert Body to JSON"
            return $false
        }
    }

    #TODO write a caching function for calls to the same path

    Write-Log -Level 7 -Text "HTTP $Method $($script:SiteURL)/$Path`?_format=json"
    $Resource = Invoke-RestMethod `
        -Uri "$($script:SiteURL)/$Path`?_format=json" `
        -Headers $headers `
        -Method $Method `
        -Body $Body
    
    if ($Simplify) {
        return Get-SimplifiedDrupalObject $Resource
    } else {
        return $Resource
    }
}

function Test-ComputerConnections {
    param (
        [string[]]$ComputerNames
    )

	$Results = @()
    $Results += $ComputerNames | ForEach-Object -Parallel {
        $response = Test-Connection -TargetName $_ -Count 1 -ErrorAction SilentlyContinue
		if ($response.reply.status -eq 'Success') {
            return $_
        } 
    } -ThrottleLimit 100

    return $Results
}

function Write-Log {
param(
  [string]$Text,
  [int]$Level
)
    $Time = get-date -Format "yyyy-MM-dd-hh-mm-ss"
    if ($Level -le $script:loglevel) {
        Write-Host "$time[$Level]: $Text"
        "$time[$Level]: $Text" | Out-File -Append -FilePath $script:logfile -Encoding utf8
    }
}

function Get-SimplifiedDrupalObject {
    param(
        [Parameter(ValueFromPipelineByPropertyName)]$Objects
    )
    process {
        foreach ($Object in $Objects) {
            foreach ($property in $Object.PsObject.Properties) {
                if ($null -ne $property.Value.value) {
                    $property.Value =  @($property.Value.value)
                }
            }
        }
        return $Objects
    }
}

<#
This function wraps plain properties in @{value: originalvalue} for Drupal RESTful Resources
#>
function ConvertTo-DrupalResource {
    param(
        $Object
    )
    
    foreach ($property in $Object.PsObject.Properties) {        
        if ($property.name -ne 'type' -AND $property.value -isnot [System.Management.Automation.PSCustomObject]) {
            $Object.PsObject.Properties.Remove($property.name)
            $Object | Add-Member -MemberType NoteProperty `
                -Name $property.name `
                -Value @([PSCustomObject]@{ "value" = $property.value })
        }
    }
    return $Object
}

function Get-AssetInfo {
    param (
        [string]$DeviceName = (Throw "No DeviceName provided for Get-AssetInfo")
    )
	
    try {
		Write-Log -Level 8 -Text "Starting CimSession Connecting to $DeviceName..."
		$DCOM = New-CimSessionOption -Protocol Dcom
		$CimSession = New-CimSession -ComputerName $DeviceName -SessionOption $DCOM -ErrorAction SilentlyContinue
		
		if (! $cimSession) {
			return $null
		}
		# Run Get-CimInstance command to retrieve asset information
		$computersystem = Get-CimInstance -ClassName Win32_ComputerSystem -CimSession $CimSession
		$bios = Get-CimInstance -ClassName Win32_BIOS -CimSession $CimSession
		Remove-CimSession $CimSession
		
		# Create a custom object with relevant information
		$assetInfo = [PSCustomObject]@{
			DeviceName = $DeviceName
			Manufacturer = $computersystem.Manufacturer
			Model = $computersystem.Model
			SerialNumber = $bios.SerialNumber
			BIOSVersion = $bios.SMBIOSBIOSVersion
			SystemType = $computersystem.SystemType
			NumberOfLogicalProcessors = $computersystem.NumberOfLogicalProcessors
			TotalPhysicalMemory = $computersystem.TotalPhysicalMemory
		}
		return $assetInfo
		
        
    } catch {
        Write-Log -Level 3 -Text "Error executing PowerShell command: $_"
        return $null
    }
}
#So we can call in a parallel loop later https://tighetec.co.uk/2022/06/01/passing-functions-to-foreach-parallel-loop/
#$getAssetInfoFunction = ${function:Get-AssetInfo}.ToString()

Main