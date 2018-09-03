# The following command will set $Disk to all USB drives with >20 GB of storage

$Disk = Get-Disk | Where-Object {$_.Path -match "USBSTOR" -and $_.Size -gt 20Gb -and -not $_.IsBoot } | Out-GridView -PassThru

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

#Clear the disk. This will delete any data on the disk. (and will fail if the disk is not yet initialized. If that happens, simply continue with ‘New-Partition…) Validate that this is the correct disk that you want to completely erase.
#
# To skip the confirmation prompt, append –confirm:$False
Clear-Disk -number $Disk.DiskNumber -RemoveData

# This command initializes a new MBR disk
Initialize-Disk -Number $Disk.DiskNumber -PartitionStyle MBR

$SystemPartition = New-Partition -DiskNumber $disk.Number -Size (350MB) -IsActive -AssignDriveLetter
Format-Volume -NewFileSystemLabel "UFD-System" -FileSystem FAT32 -Partition $SystemPartition | Out-Null
$bootDvrLtr = $SystemPartition.DriveLetter

# This command creates the Windows volume using the maximum space available on the drive. The Windows To Go drive should not be used for other file storage.
$OSPartition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
Format-Volume -NewFileSystemLabel "UFD-Windows" -FileSystem NTFS -Partition $OSPartition | Out-Null
$drvLtr = $OSPartition.DriveLetter

# This command sets the NODEFAULTDRIVELETTER flag on the partition which prevents drive letters being assigned to either partition when inserted into a different computer.
Set-Partition -InputObject $OSPartition -NoDefaultDriveLetter $TRUE


Expand-WindowsImage -ApplyPath "$($drvLtr)`:" -ImagePath "$($isoLtr):\sources\install.wim" -Index $imageindex
$bcdBootArgs = "$drvLtr`:\windows /s $($systemPartition.driveletter)`: /f ALL /v"
Start-Process "bcdboot.exe" -ArgumentList " $bcdBootArgs" -Wait -PassThru

$XMLObject = @"
<?xml version='1.0' encoding='utf-8' standalone='yes'?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="offlineServicing">
    <component
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        language="neutral"
        name="Microsoft-Windows-PartitionManager"
        processorArchitecture="x86"
        publicKeyToken="31bf3856ad364e35"
        versionScope="nonSxS"
        >
      <SanPolicy>4</SanPolicy>
    </component>
   <component
        xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        language="neutral"
        name="Microsoft-Windows-PartitionManager"
        processorArchitecture="amd64"
        publicKeyToken="31bf3856ad364e35"
        versionScope="nonSxS"
        >
      <SanPolicy>4</SanPolicy>
    </component>
 </settings>
 <settings pass="oobeSystem">
 <component name="Microsoft-Windows-WinRE-RecoveryAgent"
   processorArchitecture="x86"
   publicKeyToken="31bf3856ad364e35" language="neutral"
   versionScope="nonSxS"
   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
     <UninstallWindowsRE>true</UninstallWindowsRE>
 </component>
<component name="Microsoft-Windows-WinRE-RecoveryAgent"
   processorArchitecture="amd64"
   publicKeyToken="31bf3856ad364e35" language="neutral"
   versionScope="nonSxS"
   xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
   xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
     <UninstallWindowsRE>true</UninstallWindowsRE>
 </component>
</settings>
</unattend>
"@


$XMLObject | Out-File "$drvLtr`:\san_policy.xml" -Encoding utf8
Apply-WindowsUnattend -UnattendPath "$drvLtr`:\san_policy.xml" -Path "$drvLtr`:\"

$isos | Copy-Item "$drvLtr`:\"
