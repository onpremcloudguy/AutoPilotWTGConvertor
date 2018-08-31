#region config
$apFilePath = "$env:SystemDrive\tempAP"
$apFile = "$apFilePath\$($env:ComputerName).csv"
$aadSecGroup = "ZZZ - VIT Intune Devices"
#endregion
#region Functions
function Get-DeviceFromAutoPilot {
    param (
        [string]$serialNumber
    )
    $aadDevices = Get-AzureADDevice -All:$true | select-object *, @{Name = "APID"; Expression = {($_.DevicePhysicalIds | where-object {$_ -match "\[ZTDID\]"}) -replace "\[ZTDID\]:", ""}}
    $apDevice = Get-AutoPilotDevice | Where-Object {
        $_.serialNumber -eq "$serialNumber"
    }
    if ($apDevice) {
        $enrolledDevice = $aadDevices | where-object {$_.APID -eq $APDevice.id}
        if ($enrolledDevice) {
            return $enrolledDevice
        }
        else {
            return $null
        }
    }
    else {
        return $null
    }
}
#endregion
#region set up environment modules
Clear-Host
Write-Host "---------------------------------------------`nWindows To Go - AutoPilot Devie Configuration`n---------------------------------------------`n---------------------------------------------"
if (!(Test-Path -Path $apFilePath)) {
    new-item -Path $apFilePath -ItemType Directory | Out-Null
}
Write-Host "Setting up local environment.."
$nugetVer = (Get-PackageProvider -name "NuGet" -ListAvailable).version
if ($nugetVer.major -lt 2 -and $nugetVer.Minor -lt 8) {
    Install-PackageProvider -name "NuGet" -ForceBootstrap -Force | Out-Null
    Write-Host " ++ NuGet configured.."
}
if ((Get-InstalledScript -Name "Get-WindowsAutoPilotInfo").version -lt 1.3) {
    Install-Script -Name "Get-WindowsAutoPilotInfo" -Force | Out-Null
    Write-Host " ++ AP script installed.."
}
if ((Get-ExecutionPolicy).ToString() -ne "Bypass") {
    Set-ExecutionPolicy -ExecutionPolicy Bypass -Force -Scope CurrentUser
    Write-Host " ++ execution policy set to bypass.."
}
if ((Get-Module -listavailable -name AzureADPreview).count -ne 1) {
    Install-Module -name AzureADPreview -scope allusers -Force -AllowClobber | Out-Null
    Write-Host " ++ AzureADPreview module installed.."
}
else {
    Update-Module -name AzureADPreview | Out-Null
    Write-Host " ++ AzureADPreview module upgraded.."
}
Import-Module -name AzureADPreview
if ((Get-Module -listavailable -name WindowsAutoPilotIntune).count -ne 1) {
    Install-Module -name WindowsAutoPilotIntune -scope allusers -Force | Out-Null
    Write-Host " ++ WindowsAutoPilotIntune module installed.."
}
else {
    Update-Module -name WindowsAutoPilotIntune | Out-Null
    Write-Host " ++ WindowsAutoPilotIntune module upgraded.."
}
Write-Host " `nSetting up device for AutoPilot Enrollment.."
#endregion
try {
    #region Connect to Azure and check AutoPilot device enrollment details.
    Get-WindowsAutoPilotInfo -OutputFile $apFile
    $apCsv = Import-Csv $apFile
    Write-Host " ++ Serial Number: $($apCSV.'Device Serial Number').."
    Write-Host " ++ Windows PID  : $($apCSV.'Windows Product ID').."
    Write-Host " ++ Hardware Hash: $(($apCSV.'Hardware Hash').SubString(0,60)).."
    Import-Module -name WindowsAutoPilotIntune
    Write-Host " `nConnecting to Azure.."
    $azureAdmin = Connect-AzureAD -ErrorAction Stop
    Connect-AutoPilotIntune -user $azureAdmin.Account
    Write-Host " `nChecking for enrollment details..`n"
    $enrolledDevice = Get-DeviceFromAutoPilot -serialNumber $(($apCsv).'Device Serial Number')
    if (!($enrolledDevice)) {
        while (($newMachine = (Read-Host -Prompt "This device is not enrolled in AutoPilot. Would you like to enroll it now? (Y/N)")) -notmatch '[yY|nN]') { 
            Write-Host " Y or N ? " -ForegroundColor Black -BackgroundColor Yellow
        }
        if ($newMachine -match "[yY]") {
            Write-Host " ++ Enrolling device into AutoPilot.."
            Import-AutoPilotCSV -csvFile $apFile
            $enrolledDevice = Get-DeviceFromAutoPilot -serialNumber $(($apCsv).'Device Serial Number')
            Write-Host " ++ (Please note: this may take a while. A timer has been set for 25 minutes.)"
            $sw = New-Object System.Diagnostics.Stopwatch
            $sw.Start()
            $ts = New-TimeSpan -Minutes 25
            while ((!($enrolledDevice)) -and ($sw.ElapsedMilliseconds -le $ts.TotalMilliseconds)) {
                Write-Progress -Activity "Enrolling Device: $(($apCsv).'Device Serial Number')" -Status "$($sw.Elapsed)" -PercentComplete ($($sw.ElapsedMilliseconds) / $($ts.TotalMilliseconds) * 100)
                Start-Sleep -Seconds 10
                $enrolledDevice = Get-DeviceFromAutoPilot -serialNumber $(($apCsv).'Device Serial Number')
            }
            $sw.Stop()
            if ($enrolledDevice) {
                Write-Host " `nDevice successfully enrolled. AAD details below.."
                $enrolledDevice
            }
            else {
                throw "Device not found. Bad news my dude."
            }
        }
        else {
            Write-Host " ++ Will not enroll this device.."
        }
    }
    else {
        $enrolledDevice
    }
    #endregion
    #region Check if device is enrolled to AD Security Group
    $aadGroup = Get-AzureADGroup -SearchString $aadSecGroup
    if ($aadGroup -and ($newMachine -match "[yY]")) {
        Write-Host " `nEnrolling device into AD Security Group: $($aadSecGroup).."
        $isMember = $aadGroup | Get-AzureADGroupMember | Where-Object {$_.ObjectId -eq $enrolledDevice.ObjectId}
        if (!($isMember)) {
            while (($secGroup = (Read-Host -Prompt "Device is not enrolled in security group $($aadSecGroup). Would you like to enroll it now? (Y/N)")) -notmatch '[yY|nN]') { 
                Write-Host " Y or N ? " -ForegroundColor Black -BackgroundColor Yellow
            }
            if ($secGroup -match "[yY]") {
                Write-Host " ++ Enrolling this device.."
                Add-AzureADGroupMember -ObjectId $aadGroup.ObjectId -RefObjectId $enrolledDevice.ObjectId
            }
        }
        else {
            Write-Host " ++ Will not enroll this device.."
        }
    }
    else {
        if ($newMachine -match "[yY]") {
            throw "`"$($aacSecGroup)`" Security group not found on tenant. Skipping AAD Security Enrollment"
        }
        else {
            Write-Host " ++ Device was not enrolled into AutoPilot - will skip AAD Security Group Enrollment Process.."
        }
    }
    #endregion
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Black -BackgroundColor Yellow
}
try {
    $ErrorActionPreference = "stop"
    Write-Host "`nGetting ISO images ready.."
    $isos = get-childitem -Path "c:\*" -Include *.iso
    $menu = @()
    if ($isos.Count -gt 1) {
        $i = 0
        foreach ($iso in $isos) {
            $i++
            $menu += " {0}. {1}`n" -f $i, $iso.Name
        }
        Write-Host $menu
        $r = Read-Host "`nSelect an ISO to use by number"
        $isopath = "C:\$($menu[$r-1].trim().split()[1])"
        Write-Host " ++ Going to use the following ISO to install windows: $isopath"
    }
    elseif ($isos.count -eq 1) {
        $isoPath = "c:\$($isos.name)"
        Write-Host " ++ Going to use the following ISO to install windows: $isopath"
    }
    elseif ($isos.Count -eq 0) {
        throw "Error no ISO found on the root of C: please add one"
    }
    Write-Host " ++ Mounting ISO image.."
    Mount-DiskImage $isoPath -PassThru | Out-Null
    $isoLtr = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter
    Import-Module dism
    $imageindex = 3
    $isoimage = Get-WindowsImage -ImagePath "$($isoLtr):\sources\install.wim"  | Select-Object imageindex, imagename
    Write-Host ($isoimage | Format-table | Out-String)
    $imageindex = Read-Host " `nPlease select the ImageIndex which you would like to use, default is 3"
    Write-Host " `nPreparing system for installation of Windows 10.."
    $uefi = $true
    $disk = get-disk | Where-Object {$_.isboot -notlike $True}
    $disk | Set-Disk -IsOffline $False
    $disk | set-disk -IsReadOnly $False
    $UEFIBoot = $null
    if ($disk.PartitionStyle -eq "MBR") {
        Write-Host " ++ Disk partition: MBR.."
        while (($UEFIBoot = (Read-Host -Prompt "`nCurrently using BIOS, did you want to convert to UEFI BOOT? (Y/N)")) -notmatch '[yY|nN]') { 
            Write-Host " Y or N ? " -ForegroundColor Black -BackgroundColor Yellow
        }
        if ($UEFIBoot -match '[yY]') {
            Write-Host " ++ Switching to UEFI Boot.."
            Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$False -RemoveOEM
            Initialize-Disk -Number $disk.DiskNumber -PartitionStyle GPT
            $systemPartition = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
            #$systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$False
            Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$False | Out-Null
            $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
            $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
            $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
            $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$False
            $drvLtr = $windowsPartition.DriveLetter
            $uefi = $true
        }
        else {
            Write-Host " ++ Staying with BIOS.."
            Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$False -RemoveOEM
            Initialize-Disk -Number $disk.DiskNumber -PartitionStyle MBR
            $sysPar = New-Partition -DiskNumber $disk.DiskNumber -UseMaximumSize -MbrType IFS -IsActive -AssignDriveLetter
            $drvLtr = $sysPar.DriveLetter
            #$sysVol = Format-Volume -Partition $sysPar -FileSystem NTFS -Force -Confirm:$False
            Format-Volume -Partition $sysPar -FileSystem NTFS -Force -Confirm:$False | Out-Null
            $uefi = $False    
        }
    }
    elseif ($disk.PartitionStyle -eq "GPT") {
        Write-Host " ++ Disk partition: GPT.."
        Clear-Disk -Number $disk.DiskNumber -RemoveData -Confirm:$False -RemoveOEM
        Initialize-Disk -Number $disk.DiskNumber -PartitionStyle GPT
        $systemPartition = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
        #$systemVolume = Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$False
        Format-Volume -Partition $systemPartition -FileSystem FAT32 -Force -Confirm:$False | Out-Null
        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        $systemPartition | Add-PartitionAccessPath -AssignDriveLetter
        $windowsPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -AssignDriveLetter
        $windowsVolume = Format-Volume -Partition $windowsPartition -FileSystem NTFS -Force -Confirm:$False
        $drvLtr = $windowsPartition.DriveLetter
        $uefi = $true
    }
    Expand-WindowsImage -ApplyPath "$($drvLtr)`:" -ImagePath "$($isoLtr):\sources\install.wim" -Index $imageindex
    if ($uefi) {
        $bcdBootArgs = "$drvLtr`:\windows /s $($systemPartition.driveletter)`: /v"
    }
    else {
        $bcdBootArgs = "$drvLtr`:\windows /s $drvLtr`: /v /f BIOS"
    }
    Write-Host "`nStarting BCDBoot.exe with arguments $($bcdBootArgs)" 
    Start-Process "bcdboot.exe" -ArgumentList " $bcdBootArgs" -Wait
    Write-Host "`nSetting system disk to RO and taking offline.."
    $disk | set-disk -isreadonly $True
    $disk | set-disk -isoffline $True
    $isoPath | Dismount-DiskImage
    if ($UEFIBoot -match '[yY]') {
        Write-Host "`nYou need to change the firmware manually to set it to use UEFI" -ForegroundColor Black -BackgroundColor Green
    }
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Black -BackgroundColor Red
}