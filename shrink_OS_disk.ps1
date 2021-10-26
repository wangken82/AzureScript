#This is a script to shrink the windows OS disk size, Created by Kenneth 22-OCT-2021
#General steps will be 
#1. Shrink disk size inside OS
#2. Deallocate the VM, backup the OS disk with snapshot. (name $VMname+OSSnapshot+date)
#3. Run this script.
#3.1 Create storage account named temp-xxx to hold the temp disks
#3.2 Create a new temp disk(desired small size) in the new Storage Account,then read the footer from this small disk
#3.3 Copy the Managed OS Disk into the temp Storage Account
#3.4 Change the footer (size) so the OS disk shrinks (footer info from step 3.2)
#3.5 Convert the unmamge OS disk back to a Managed Disk
#3.6 Swap the VM’s current OS disk with the new managed smaller OS Disk
#3.7 Clean up the temp storage account and the old managed disk
#3.8 Snapshot created in step2 will not be removed by this script

#
# Variables
$DiskID = "/subscriptions/955ad7d0-a2bc-4ec0-a274-46e0c07ca535/resourceGroups/Asia_lab/providers/Microsoft.Compute/disks/128win7_OsDisk_1_761347e144b640d1a5bc293e9a3fb177"
$VMName = "128win7"
$DiskSizeGB = 32

#Auto set Variable
$AzSubscription = $DiskID.substring(15,36)
$snapshotname = $VMName+"-OSSnapshot-"+(get-date).ToString(‘M/d/yyyy’).replace('/','')

# Script begins
# Log into AzAccount
Connect-AzAccount

#Provide the subscription Id of the subscription where snapshot is created
Select-AzSubscription -Subscription $AzSubscription

# VM to resize disk of
$VM = Get-AzVm | ? Name -eq $VMName

#Stop the VM and did a Sanpshot of the OS disk
$VM | Stop-AzVM
$snapshot = New-AzSnapshotConfig `
    -SourceUri $VM.StorageProfile.OsDisk.ManagedDisk.Id `
    -Location $VM.Location `
    -CreateOption copy

New-AzSnapshot `
    -Snapshot $snapshot `
    -SnapshotName $snapshotname `
    -ResourceGroupName $VM.ResourceGroupName `



#Provide the name of your resource group where snapshot is created
$resourceGroupName = $VM.ResourceGroupName

# Get Disk from ID
$Disk = Get-AzDisk | ? Id -eq $DiskID

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# Get Disk Name from Disk
$DiskName = $Disk.Name

# Get SAS URI for the Managed disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;


#You can use current storage account or use script to create a new one temporarily(will be deleted at the end of script)
$storageAccountName = "temp" + [system.guid]::NewGuid().tostring().replace('-','').substring(1,18)

#Name of the storage container where the downloaded snapshot will be stored
$storageContainerName = "mycontainer"


#Provide the name of the VHD file to which snapshot will be copied.
$destinationVHDFile = "$($VM.StorageProfile.OsDisk.Name).vhd"


#Create the context for the storage account which will be used to copy blob to temp storage account 
$StorageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -SkuName Standard_LRS -Location $VM.Location
$destinationContext = $StorageAccount.Context
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

#Copy the OS disk blob to storage account and wait for it to complete
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFile -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFile -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 60 }

$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

#A new Emtpy disk, will get the footer from this empty disk & write to OS disk
$emptydiskforfooter = "$($VM.StorageProfile.OsDisk.Name)-empty.vhd"


# create new empty disk to get the footer (this is a managed disk), createOption= empty
$diskConfig = New-AzDiskConfig `
    -Location $VM.Location `
    -CreateOption Empty `
    -DiskSizeGB $DiskSizeGB `
    -Zone $VM.Zones `
    -HyperVGeneration $HyperVGen

$dataDisk = New-AzDisk `
    -ResourceGroupName $resourceGroupName `
    -DiskName $emptydiskforfooter `
    -Disk $diskConfig


#Attach the empty to VM
$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $emptydiskforfooter `
    -CreateOption Attach `
    -ManagedDiskId $dataDisk.Id `
    -Lun 63

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Stop-AzVM -Force


# Get SAS token for the empty disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfooter -Access 'Read' -DurationInSecond 600000;

# Copy the managed empty disk to blob storage account
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $emptydiskforfooter -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfooter -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 60 }

$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfooter

# Deattach temp empty disk (managed disk) from VM
Remove-AzVMDataDisk -VM $VM -DataDiskNames $emptydiskforfooter
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Delete temp disk(managed disk)
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfooter -Force;

# Get the blobs for copied os disk and empty disk.(non-managed disks)
$emptyDiskblob = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $emptydiskforfooter
$osdisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFile

#get the value for footer
write-output "Get footer of empty disk"
$footer = New-Object -TypeName byte[] -ArgumentList 512
$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)

write-output "Write footer of empty disk to OSDisk"
$osDisk.ICloudBlob.Resize($emptyDiskblob.Length)
$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
$osDisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)

#remove the copied empty disk from storage account
Write-Output -InputObject "Removing empty disk blobs"
$emptyDiskblob | Remove-AzStorageBlob -Force


#Provide the new name of the Managed OS Disk, will do os swap later
$NewDiskName = "$DiskName" + "-small"

#Create the new disk with the same SKU as the current one
$accountType = $Disk.Sku.Name

# Get the new disk URI
$vhdUri = $osdisk.ICloudBlob.Uri.AbsoluteUri

# Specify the disk options,createOption=import, it will create managed disk from current unmanage disk 
$diskConfig = New-AzDiskConfig -AccountType $accountType -Location $VM.location -Zone $VM.Zones -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen

#Create Managed disk
$NewManagedOSDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

$VM | Stop-AzVM -Force

# Set the VM configuration to point to the new disk  
Set-AzVMOSDisk -VM $VM -ManagedDiskId $NewManagedOSDisk.Id -Name $NewManagedOSDisk.Name

# Update the VM with the new OS disk
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

Write-Output -InputObject "Starting VM after os resize"

$VM | Start-AzVM

Write-Output -InputObject "VM started, pls check state on portal, sleep 180 seconds"
start-sleep 180

# Please check the VM is running before proceeding with the below tidy-up steps

Write-Output -InputObject "Cleanup temp resources"
# Delete old Managed OS Disk
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force;

# Delete old blob storage
$osdisk | Remove-AzStorageBlob -Force

# Delete temp storage account
$StorageAccount | Remove-AzStorageAccount -Force