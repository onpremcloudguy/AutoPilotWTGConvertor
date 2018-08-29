$apFilePath = "c:\tempap"
$apFile = "$apFilePath\$($env:computername).csv"
$aadSecGroup = "AAD AP Group"
if (!(Test-Path -Path $apFilePath)) {
    new-item -Path $apFilePath -ItemType Directory | Out-Null
}
$nugetVer = (Get-PackageProvider -name "NuGet" -ListAvailable).version
if ($nugetVer.major -lt 2 -and $nugetVer.Minor -lt 8) {
    Install-PackageProvider -name "nuget" -ForceBootstrap -Force -Verbose
}
if ((Get-InstalledScript -Name "get-windowsautopilotinfo").version -lt 1.3) {
    Install-Script -Name "get-windowsautopilotinfo" -Force -Verbose
}
if ((Get-ExecutionPolicy).ToString() -ne "Bypass") {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force -Scope CurrentUser
}
get-windowsautopilotinfo.ps1 -OutputFile $apFile

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
$azureAdmin = connect-azuread
$apConnect = Import-Csv $apFile
Connect-AutoPilotIntune -user $azureAdmin.Account
Import-AutoPilotCSV -csvFile $apFile
$grp = get-azureadgroup -SearchString $aadSecGroup
$choice = read-host "Wait to be added to group?"
while ($choice -notmatch "[y|n]") {
    $choice = read-host "Do you want to continue? (Y/N)"
}
if ($choice -eq "y") {
    foreach ($ap in $apConnect) {
        while ((Get-AzureADDevice -SearchString $ap.'Device Serial Number').count -ne 1) {Start-Sleep -Seconds 10}
        $device = Get-AzureADDevice -SearchString $ap.'Device Serial Number'
        Add-AzureADGroupMember -ObjectId $grp.objectid -RefObjectId $device.objectid
    }
}
$ErrorActionPreference = "stop"

$disk = get-disk | Where-Object {$_.isboot -notlike $True}
$disk | Set-Disk -IsOffline $False
$disk | set-disk -IsReadOnly $False
if ($disk.PartitionStyle -eq "MBR") {
    Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$False -RemoveOEM
    Initialize-Disk -Number $disk.DiskNumber -PartitionStyle MBR
    $sysPar = New-Partition -DiskNumber $disk.DiskNumber -UseMaximumSize -MbrType IFS -IsActive -AssignDriveLetter
    $drvLtr = $sysPar.DriveLetter
    $sysVol = Format-Volume -Partition $sysPar -FileSystem NTFS -Force -Confirm:$False
    
}
elseif ($disk.PartitionStyle -eq "GPT") {
    Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$False -RemoveOEM
    Initialize-Disk -Number $disk.DiskNumber -PartitionStyle GPT
    
    $systemPartition = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

    $systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$False

    $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
    $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'

    $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$False
    $drvLtr = $windowsVolume.DriveLetter
}
$isoPath = "C:\en_windows_10_business_editions_version_1803_updated_march_2018_x64_dvd_12063333.iso"
$ISOdisk = Mount-DiskImage $isoPath -PassThru
$isoLtr = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter
Import-Module dism
Expand-WindowsImage -ApplyPath "$($drvLtr)`:" -ImagePath "$($isoLtr):\sources\install.wim" -Index 3

$bcdBootArgs = "$drvLtr`:\windows /s $($systemPartition.driveletter)`: /v"
Start-Process "bcdboot.exe" -ArgumentList " $bcdBootArgs" -Wait

$disk | set-disk -isreadonly $True
$disk | set-disk -isoffline $True
$isoPath | Dismount-DiskImage