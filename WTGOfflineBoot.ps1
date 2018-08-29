$apfilepath = "c:\tempap"
$apfile = "$apfilepath\$($env:computername).csv"
$aadsecgroup = "AAD AP Group"
if (!(Test-Path -Path $apfilepath)) {
    new-item -Path $apfilepath -ItemType Directory
}
$nugetver = (Get-PackageProvider -name "NuGet").version
if ($nugetver.major -lt 2 -and $nugetver.Minor -lt 8) {
    Install-PackageProvider -name "nuget" -ForceBootstrap -Force | Out-Null
}
if ((Get-InstalledScript -Name "get-windowsautopilotinfo").version -lt 1.3) {
    Install-Script -Name "get-windowsautopilotinfo" -Force
}
if ((Get-ExecutionPolicy).ToString() -ne "Bypass") {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force -Scope CurrentUser
}
get-windowsautopilotinfo.ps1 -OutputFile $apfile

if ((get-module -listavailable -name AzureADPreview).count -ne 1) {
    install-module -name AzureADPreview -scope allusers -Force -AllowClobber
}
else {
    update-module -name AzureADPreview
}
import-module -name AzureADPreview
if ((get-module -listavailable -name WindowsAutoPilotIntune).count -ne 1) {
    install-module -name WindowsAutoPilotIntune -scope allusers -Force
}
else {
    update-module -name WindowsAutoPilotIntune
}
import-module -name WindowsAutoPilotIntune
connect-azuread
$apcontent = Import-Csv $apfile
Connect-AutoPilotIntune -user $adminuser | Out-Null
Import-AutoPilotCSV -csvFile $apfile
$grp = get-azureadgroup -SearchString $aadsecgroup
$choice = "Wait to be added to group?"
while ($choice -notmatch "[y|n]") {
    $choice = read-host "Do you want to continue? (Y/N)"
}
if ($choice -eq "y") {
    foreach ($ap in $apcontent) {
        while ((Get-AzureADDevice -SearchString $ap.'Device Serial Number').count -ne 1) {Start-Sleep -Seconds 10}
        $device = Get-AzureADDevice -SearchString $ap.'Device Serial Number'
        Add-AzureADGroupMember -ObjectId $grp.objectid -RefObjectId $device.objectid
    }
}
$ErrorActionPreference = "stop"

$disk = get-disk | Where-Object {$_.isboot -notlike $true}
$disk | Set-Disk -IsOffline $false
$disk | set-disk -IsReadOnly $false
if ($disk.PartitionStyle -eq "MBR") {
    Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$false -RemoveOEM
    Initialize-Disk -Number $disk.DiskNumber -PartitionStyle MBR
    $syspar = New-Partition -DiskNumber $disk.DiskNumber -UseMaximumSize -MbrType IFS -IsActive -AssignDriveLetter
    $drvltr = $syspar.DriveLetter
    $sysvol = Format-Volume -Partition $syspar -FileSystem NTFS -Force -Confirm:$false
    
}
elseif ($disk.PartitionStyle -eq "GPT") {
    $OSpar = $disk | Get-Partition | Sort-Object Size -Descending | Select-Object -First 1
    if ($ospar.size -lt 64Gb) {
        $ospar = $disk | New-Partition -UseMaximumSize -AssignDriveLetter
    }
    $drvltr = $OSpar.DriveLetter
    Format-Volume -DriveLetter $drvltr -FileSystem NTFS
}
$isopath = "C:\en_windows_10_business_editions_version_1803_updated_march_2018_x64_dvd_12063333.iso"
$ISOdisk = Mount-DiskImage $isopath -PassThru
$isoltr = (Get-DiskImage -ImagePath $isopath | Get-Volume).DriveLetter
Import-Module dism
Expand-WindowsImage -ApplyPath "$($drvltr)`:" -ImagePath "$($isoltr):\sources\install.wim" -Index 3
if (!(test-path -Path "$($drvltr):\efi\microsoft\boot\bcd")) {
    $bcdbootargs = "$($drvltr):\windows /s $drvltr`: /v /f UEFI"
    Start-Process "bcdboot.exe" -ArgumentList " $bcdbootargs" -Wait
    Start-Process "bcdboot.exe" -ArgumentList "/store $($drvltr):\efi\microsoft\boot\bcd /set `{bootmgr`} device locate" -Wait
    Start-Process "bcdboot.exe" -ArgumentList "/store $($drvltr):\efi\microsoft\boot\bcd /set `{default`} device locate" -Wait
    Start-Process "bcdboot.exe" -ArgumentList "/store $($drvltr):\efi\microsoft\boot\bcd /set `{default`} osdevice locate" -Wait
}
$disk | set-disk -isreadonly $true
$disk | set-disk -isoffline $true
$isopath | Dismount-DiskImage
