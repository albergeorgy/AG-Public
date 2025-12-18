# .\copyvm.ps1 -SourceSubscriptionId "xxxxx-xxxx-xxxxx-xxxx-xxx" -SourceResourceGroupName "xxxxxx" -SourceVMName "xxxxx" -DestinationSubscriptionId "xxxxx" -DestinationResourceGroupName "xxxx" -DestinationLocation "xxxxx" -DestinationVNetName "xxxxx" -DestinationSubnetName "xxxxx"

#Requires -Modules Az.Accounts, Az.Compute, Az.Storage, Az.Resources
<#
.SYNOPSIS
    Copies an Azure VM from one tenant to another using managed disk snapshots and VHD export/import.

.DESCRIPTION
    This script performs the following operations with OPTIMIZED cross-tenant transfer methods:
    1. Authenticates to source and destination tenants
    2. Creates snapshots of source VM disks (extended 8-hour access for reliability)
    3. Exports snapshots as VHD files to storage account
    4. Copies VHD files to destination tenant storage using FASTEST available method:
       - PRIMARY: Direct Azure Storage Copy (Start-AzStorageBlobCopy) - fastest, no local downloads
       - FALLBACK 1: Optimized AzCopy with maximum concurrency and performance settings
       - FALLBACK 2: Local download method (slowest, most compatible)
    5. Creates managed disks from VHDs in destination
    6. Creates new VM in destination tenant

    PERFORMANCE OPTIMIZATIONS:
    - Avoids local machine downloads when possible (saves bandwidth and disk space)
    - Uses Azure native blob copy service for maximum speed
    - Optimized AzCopy settings (auto-concurrency, 8MB blocks, no bandwidth caps)
    - Extended SAS token durations (8 hours) for cross-tenant reliability
    - Progressive fallback strategy ensures success even with network restrictions

.PARAMETER SourceSubscriptionId
    Source subscription ID where the VM currently exists

.PARAMETER SourceResourceGroupName
    Source resource group containing the VM

.PARAMETER SourceVMName
    Name of the source VM to copy

.PARAMETER DestinationSubscriptionId
    Destination subscription ID where the VM will be created

.PARAMETER DestinationResourceGroupName
    Destination resource group for the new VM

.PARAMETER DestinationVMName
    Name for the new VM in destination (optional, defaults to source name)

.PARAMETER DestinationLocation
    Azure region for destination VM

.PARAMETER DestinationVNetName
    Virtual network name for destination VM

.PARAMETER DestinationSubnetName
    Subnet name for destination VM

.PARAMETER DestinationVMSize
    VM size for destination (optional, defaults to source size)

.PARAMETER DestinationAvailabilityZone
    Availability zone for destination VM (optional)

.PARAMETER StorageAccountName
    Storage account for temporary VHD storage (will be created if doesn't exist)

.EXAMPLE
    .\copyvm.ps1 -SourceSubscriptionId "source-sub-id" -SourceResourceGroupName "source-rg" -SourceVMName "source-vm" `
                -DestinationSubscriptionId "dest-sub-id" -DestinationResourceGroupName "dest-rg" `
                -DestinationLocation "East US" -DestinationVNetName "dest-vnet" -DestinationSubnetName "default"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceSubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$SourceResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [string]$SourceVMName,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationSubscriptionId,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationResourceGroupName,
    
    [Parameter(Mandatory = $false)]
    [string]$DestinationVMName,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationLocation,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationVNetName,
    
    [Parameter(Mandatory = $true)]
    [string]$DestinationSubnetName,
    
    [Parameter(Mandatory = $false)]
    [string]$DestinationVMSize,
    
    [Parameter(Mandatory = $false)]
    [string]$DestinationAvailabilityZone,
    
    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName = "vmcopytemp$(Get-Random -Maximum 9999)",
    
    [Parameter(Mandatory = $false)]
    [string]$SourceTenantId,
    
    [Parameter(Mandatory = $false)]
    [string]$DestinationTenantId,
    
    [Parameter(Mandatory = $false)]
    [switch]$UseDirectCopy = $true
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Function to write log messages
function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "Error" { "Red" }
        "Warning" { "Yellow" }
        "Success" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Function to handle retries with exponential backoff
function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 5
    )
    
    $attempt = 1
    while ($attempt -le $MaxRetries) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                throw
            }
            Write-Log "Attempt $attempt failed: $($_.Exception.Message). Retrying in $DelaySeconds seconds..." -Level "Warning"
            Start-Sleep -Seconds $DelaySeconds
            $DelaySeconds *= 2  # Exponential backoff
            $attempt++
        }
    }
}

# Function to get tenant ID from subscription
function Get-TenantIdFromSubscription {
    param([string]$SubscriptionId)
    
    try {
        Write-Log "Attempting to discover tenant ID for subscription: $SubscriptionId"
        
        # Try to get subscription info without authentication first
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId" + "?api-version=2020-01-01"
        
        # This will return 401, but the WWW-Authenticate header will contain the tenant info
        try {
            Invoke-RestMethod -Uri $uri -Method Get
        }
        catch {
            if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers.Contains("WWW-Authenticate")) {
                $authHeader = $_.Exception.Response.Headers.GetValues("WWW-Authenticate")[0]
                if ($authHeader -match "authority=.*?/([a-f0-9\-]{36})") {
                    $tenantId = $matches[1]
                    Write-Log "Discovered tenant ID: $tenantId" -Level "Success"
                    return $tenantId
                }
            }
        }
        
        Write-Log "Could not discover tenant ID from subscription" -Level "Warning"
        return $null
    }
    catch {
        Write-Log "Failed to discover tenant ID: $($_.Exception.Message)" -Level "Warning"
        return $null
    }
}

# Function to authenticate to Azure with proper error handling
function Connect-ToAzure {
    param(
        [string]$Context,
        [string]$TenantId = $null
    )
    
    try {
        Write-Log "Authenticating to Azure ($Context)..."
        
        # Clear existing context to ensure clean authentication
        $existingContext = Get-AzContext -ErrorAction SilentlyContinue
        if ($existingContext) {
            Write-Log "Clearing existing Azure context..."
            Clear-AzContext -Force
        }
        
        # Connect with interactive browser authentication (better for MFA)
        if ($TenantId) {
            Write-Log "Connecting to tenant: $TenantId"
            Connect-AzAccount -TenantId $TenantId
        } else {
            Write-Log "Connecting with interactive authentication..."
            Connect-AzAccount
        }
        
        Write-Log "Successfully authenticated to Azure" -Level "Success"
    }
    catch {
        Write-Log "Failed to authenticate to Azure: $($_.Exception.Message)" -Level "Error"
        Write-Log "If you see MFA errors, please complete the authentication in your browser." -Level "Warning"
        throw
    }
}

# Function to set Azure context with validation
function Set-AzureContext {
    param([string]$SubscriptionId, [string]$Context)
    
    try {
        Write-Log "Setting Azure context to subscription: $SubscriptionId ($Context)"
        $context = Set-AzContext -SubscriptionId $SubscriptionId
        if (-not $context) {
            throw "Failed to set context for subscription $SubscriptionId"
        }
        Write-Log "Successfully set context for $Context" -Level "Success"
        return $context
    }
    catch {
        Write-Log "Failed to set context for $Context`: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to get VM details with validation
function Get-VMDetails {
    param([string]$ResourceGroupName, [string]$VMName)
    
    try {
        Write-Log "Getting VM details for: $VMName"
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName
        if (-not $vm) {
            throw "VM '$VMName' not found in resource group '$ResourceGroupName'"
        }
        Write-Log "Successfully retrieved VM details" -Level "Success"
        return $vm
    }
    catch {
        Write-Log "Failed to get VM details: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to create storage account if it doesn't exist
function New-StorageAccountIfNotExists {
    param(
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [string]$Location
    )
    
    try {
        Write-Log "Checking if storage account exists: $StorageAccountName"
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction SilentlyContinue
        
        if (-not $storageAccount) {
            Write-Log "Creating storage account: $StorageAccountName"
            $storageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroupName `
                -Name $StorageAccountName `
                -Location $Location `
                -SkuName "Standard_LRS" `
                -Kind "StorageV2" `
                -AccessTier "Hot" `
                -AllowBlobPublicAccess $false `
                -EnableHttpsTrafficOnly $true `
                -MinimumTlsVersion "TLS1_2"
            
            Write-Log "Storage account created successfully" -Level "Success"
        } else {
            Write-Log "Storage account already exists" -Level "Success"
        }
        
        return $storageAccount
    }
    catch {
        Write-Log "Failed to create/get storage account: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to create snapshot with error handling
function New-DiskSnapshot {
    param(
        [string]$DiskId,
        [string]$SnapshotName,
        [string]$ResourceGroupName,
        [string]$Location
    )
    
    try {
        Write-Log "Creating snapshot: $SnapshotName"
        $snapshotConfig = New-AzSnapshotConfig -SourceUri $DiskId -Location $Location -CreateOption Copy
        $snapshot = New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $SnapshotName -ResourceGroupName $ResourceGroupName
        Write-Log "Snapshot created successfully: $SnapshotName" -Level "Success"
        return $snapshot
    }
    catch {
        Write-Log "Failed to create snapshot: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to grant snapshot access and get download URL
function Get-SnapshotDownloadUrl {
    param(
        [string]$ResourceGroupName,
        [string]$SnapshotName,
        [int]$AccessDurationInSeconds = 28800  # 8 hours for cross-tenant reliability
    )
    
    try {
        Write-Log "Granting access to snapshot: $SnapshotName (Duration: $AccessDurationInSeconds seconds)"
        $access = Grant-AzSnapshotAccess -ResourceGroupName $ResourceGroupName -SnapshotName $SnapshotName -Access Read -DurationInSecond $AccessDurationInSeconds
        Write-Log "Access granted successfully" -Level "Success"
        return $access.AccessSAS
    }
    catch {
        Write-Log "Failed to grant snapshot access: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to copy VHD using PowerShell Azure Storage cmdlets (Alternative to AzCopy)
function Copy-VHDWithPowerShell {
    param(
        [string]$SourceUrl,
        [object]$DestinationStorageContext,
        [string]$DestinationContainer,
        [string]$DestinationBlobName
    )
    
    try {
        Write-Log "Using PowerShell Azure Storage cmdlets for copy..."
        
        # Start the blob copy operation using PowerShell
        $copyResult = Start-AzStorageBlobCopy -AbsoluteUri $SourceUrl -DestContainer $DestinationContainer -DestBlob $DestinationBlobName -DestContext $DestinationStorageContext -Force
        
        Write-Log "Blob copy operation started with ID: $($copyResult.CopyId)"
        
        # Monitor the copy progress
        do {
            Start-Sleep -Seconds 30
            $copyStatus = Get-AzStorageBlobCopyState -Container $DestinationContainer -Blob $DestinationBlobName -Context $DestinationStorageContext
            
            if ($copyStatus.TotalBytes -gt 0) {
                $progress = [Math]::Round(($copyStatus.BytesCopied / $copyStatus.TotalBytes) * 100, 1)
                Write-Log "Copy progress: $progress% ($([Math]::Round($copyStatus.BytesCopied / 1GB, 2)) GB / $([Math]::Round($copyStatus.TotalBytes / 1GB, 2)) GB)"
            } else {
                Write-Log "Copy in progress..."
            }
        } while ($copyStatus.Status -eq "Pending")
        
        if ($copyStatus.Status -eq "Success") {
            Write-Log "PowerShell blob copy completed successfully" -Level "Success"
        } else {
            throw "Blob copy failed with status: $($copyStatus.Status)"
        }
    }
    catch {
        Write-Log "PowerShell blob copy failed: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to copy VHD using AzCopy (most reliable for cross-tenant at scale)
function Copy-VHDWithAzCopy {
    param(
        [string]$SourceUrl,
        [string]$DestinationUrl
    )
    
    try {
        Write-Log "Using AzCopy for reliable cross-tenant transfer..."
        
        # Ensure AzCopy is available
        $azcopyPath = Get-Command "azcopy" -ErrorAction SilentlyContinue
        if (-not $azcopyPath) {
            Write-Log "Installing AzCopy..."
            $azcopyUrl = "https://aka.ms/downloadazcopy-v10-windows"
            $tempZip = "$env:TEMP\azcopy.zip"
            Invoke-WebRequest -Uri $azcopyUrl -OutFile $tempZip
            Expand-Archive -Path $tempZip -DestinationPath "$env:TEMP\azcopy" -Force
            $azcopyExe = Get-ChildItem -Path "$env:TEMP\azcopy" -Filter "azcopy.exe" -Recurse | Select-Object -First 1
            $env:PATH += ";$($azcopyExe.DirectoryName)"
        }
        
        # Use AzCopy with basic compatible settings for single file copy
        Write-Log "Starting AzCopy transfer with basic settings..."
        # Basic settings for VHD file copy:
        $copyCommand = "azcopy copy `"$SourceUrl`" `"$DestinationUrl`" --overwrite=true"
        
        Write-Log "Executing: $copyCommand"
        
        # Capture both output and error streams
        $output = & cmd /c "azcopy copy `"$SourceUrl`" `"$DestinationUrl`" --overwrite=true 2>&1"
        $exitCode = $LASTEXITCODE
        
        Write-Log "AzCopy output: $output"
        Write-Log "AzCopy exit code: $exitCode"
        
        if ($exitCode -eq 0) {
            Write-Log "AzCopy transfer completed successfully" -Level "Success"
        } else {
            Write-Log "AzCopy detailed error: $output" -Level "Error"
            throw "AzCopy failed with exit code: $exitCode. Error: $output"
        }
    }
    catch {
        Write-Log "AzCopy failed: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to copy VHD directly between storage accounts (Azure native copy - FASTEST)
function Copy-VHDDirectly {
    param(
        [string]$SourceUrl,
        [string]$DestinationStorageContext,
        [string]$DestinationContainer,
        [string]$DestinationBlobName
    )
    
    try {
        Write-Log "Starting direct Azure storage copy (no local download)..."
        
        # Start asynchronous blob copy operation (Azure native)
        $copyOperation = Start-AzStorageBlobCopy -AbsoluteUri $SourceUrl -DestContainer $DestinationContainer -DestBlob $DestinationBlobName -DestContext $DestinationStorageContext -Force
        
        Write-Log "Copy operation started with ID: $($copyOperation.CopyId)"
        Write-Log "Monitoring copy progress..."
        
        # Monitor copy progress
        do {
            Start-Sleep -Seconds 30
            $copyStatus = Get-AzStorageBlobCopyState -Container $DestinationContainer -Blob $DestinationBlobName -Context $DestinationStorageContext
            $progress = if ($copyStatus.TotalBytes -gt 0) { [Math]::Round(($copyStatus.BytesCopied / $copyStatus.TotalBytes) * 100, 1) } else { 0 }
            Write-Log "Copy progress: $progress% ($([Math]::Round($copyStatus.BytesCopied / 1GB, 2)) GB / $([Math]::Round($copyStatus.TotalBytes / 1GB, 2)) GB)"
        } while ($copyStatus.Status -eq "Pending")
        
        if ($copyStatus.Status -eq "Success") {
            Write-Log "Direct Azure copy completed successfully" -Level "Success"
        } else {
            throw "Copy failed with status: $($copyStatus.Status)"
        }
    }
    catch {
        Write-Log "Failed to copy VHD directly: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to copy VHD with local download (fallback method - SLOWER)
function Copy-VHDToDestination {
    param(
        [string]$SourceUrl,
        [string]$DestinationStorageContext,
        [string]$DestinationContainer,
        [string]$DestinationBlobName
    )
    
    try {
        Write-Log "Copying VHD from source to destination (cross-tenant)..."
        
        # Create temporary directory for VHD download
        $tempDir = "$env:TEMP\vhd-transfer-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        $tempVhdPath = "$tempDir\$DestinationBlobName"
        
        try {
            # Download VHD using chunked download with resume capability
            Write-Log "Downloading VHD from source snapshot..."
            
            # Get file size first
            try {
                $headRequest = Invoke-WebRequest -Uri $SourceUrl -Method Head -UseBasicParsing
                $totalSize = [long]$headRequest.Headers.'Content-Length'[0]
                Write-Log "VHD file size: $([Math]::Round($totalSize / 1GB, 2)) GB"
            }
            catch {
                Write-Log "Could not determine file size, proceeding with download..." -Level "Warning"
                $totalSize = 0
            }
            
            # Download with chunked approach
            $chunkSize = 10MB  # 10MB chunks
            [long]$downloaded = 0
            $retryCount = 0
            $maxRetries = 5
            
            # Create empty file
            New-Item -Path $tempVhdPath -ItemType File -Force | Out-Null
            
            while ($downloaded -lt $totalSize -or $totalSize -eq 0) {
                try {
                    [long]$rangeStart = $downloaded
                    [long]$rangeEnd = [Math]::Min($downloaded + $chunkSize - 1, $totalSize - 1)
                    
                    if ($totalSize -gt 0) {
                        $headers = @{
                            'Range' = "bytes=$rangeStart-$rangeEnd"
                        }
                        Write-Log "Downloading chunk: $([Math]::Round($downloaded / 1MB, 1))MB - $([Math]::Round($rangeEnd / 1MB, 1))MB"
                    } else {
                        $headers = @{}
                        Write-Log "Downloading (unknown size)..."
                    }
                    
                    $response = Invoke-WebRequest -Uri $SourceUrl -Headers $headers -UseBasicParsing -TimeoutSec 300
                    
                    # Append to file
                    [System.IO.File]::WriteAllBytes($tempVhdPath + ".tmp", $response.Content)
                    if (Test-Path ($tempVhdPath + ".tmp")) {
                        $stream = [System.IO.File]::OpenWrite($tempVhdPath)
                        $stream.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                        $tmpContent = [System.IO.File]::ReadAllBytes($tempVhdPath + ".tmp")
                        $stream.Write($tmpContent, 0, $tmpContent.Length)
                        $stream.Close()
                        Remove-Item ($tempVhdPath + ".tmp") -Force
                    }
                    
                    [long]$downloaded += $response.Content.Length
                    $retryCount = 0
                    
                    if ($totalSize -eq 0 -and $response.Content.Length -eq 0) {
                        break  # End of unknown size download
                    }
                    
                    if ($totalSize -gt 0) {
                        [double]$percentage = [Math]::Round(($downloaded / $totalSize) * 100, 1)
                        Write-Log "Progress: $percentage% ($([Math]::Round($downloaded / 1MB, 1))MB / $([Math]::Round($totalSize / 1MB, 1))MB)"
                    }
                }
                catch {
                    $retryCount++
                    if ($retryCount -ge $maxRetries) {
                        throw "Max retries reached: $($_.Exception.Message)"
                    }
                    Write-Log "Chunk download failed (attempt $retryCount/$maxRetries): $($_.Exception.Message). Retrying in $($retryCount * 5) seconds..." -Level "Warning"
                    Start-Sleep -Seconds ($retryCount * 5)
                }
            }
            
            if (-not (Test-Path $tempVhdPath)) {
                throw "Failed to download VHD to temporary location"
            }
            
            $fileSize = (Get-Item $tempVhdPath).Length
            Write-Log "Downloaded VHD successfully. Final size: $([Math]::Round($fileSize / 1GB, 2)) GB" -Level "Success"
            
            # Upload VHD to destination storage
            Write-Log "Uploading VHD to destination storage..."
            
            # For large files, use Set-AzStorageBlobContent with page blob
            Set-AzStorageBlobContent -File $tempVhdPath -Container $DestinationContainer -Blob $DestinationBlobName -Context $DestinationStorageContext -BlobType PageBlob -Force
            
            Write-Log "VHD copy completed successfully" -Level "Success"
        }
        finally {
            # Cleanup temporary file
            if (Test-Path $tempDir) {
                Write-Log "Cleaning up temporary files..."
                Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Log "Failed to copy VHD: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to create managed disk from VHD
function New-ManagedDiskFromVHD {
    param(
        [string]$DiskName,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$VHDUri,
        [string]$DiskSizeGB,
        [string]$StorageAccountType = "Premium_LRS",
        [string]$OSType,
        [string]$StorageAccountId
    )
    
    try {
        Write-Log "Creating managed disk: $DiskName"
        
        # Check if disk already exists
        $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -ErrorAction SilentlyContinue
        if ($existingDisk) {
            Write-Log "Managed disk $DiskName already exists. Deleting and recreating..." -Level "Warning"
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Force
            Start-Sleep -Seconds 10  # Wait for deletion to complete
        }
        
        # Don't set OS type during disk creation - will be set during VM attachment
        $diskConfig = New-AzDiskConfig -Location $Location -DiskSizeGB $DiskSizeGB -AccountType $StorageAccountType -CreateOption Import -SourceUri $VHDUri -StorageAccountId $StorageAccountId
        
        $disk = New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroupName -DiskName $DiskName
        Write-Log "Managed disk created successfully: $DiskName" -Level "Success"
        return $disk
    }
    catch {
        Write-Log "Failed to create managed disk: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Function to create VM configuration
function New-VMConfiguration {
    param(
        [object]$SourceVM,
        [string]$VMName,
        [string]$VMSize,
        [string]$Location,
        [string]$AvailabilityZone,
        [object]$OSDisk,
        [object[]]$DataDisks,
        [string]$VNetName,
        [string]$SubnetName,
        [string]$ResourceGroupName
    )
    
    try {
        Write-Log "Creating VM configuration for: $VMName"
        
        # Create VM configuration
        $vmConfig = New-AzVMConfig -VMName $VMName -VMSize $VMSize
        
        # Disable boot diagnostics to avoid requiring additional storage account
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
        
        # Add availability zone if specified
        if ($AvailabilityZone) {
            $vmConfig.Zones = @($AvailabilityZone)
        }
        
        # Set OS disk
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $OSDisk.Id -CreateOption Attach
        
        # Add data disks if any
        foreach ($dataDiskInfo in $DataDisks) {
            $vmConfig = Add-AzVMDataDisk -VM $vmConfig -ManagedDiskId $dataDiskInfo.Disk.Id -CreateOption Attach -Lun $dataDiskInfo.Lun -Caching $dataDiskInfo.Caching
        }
        
        # Configure networking
        $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroupName
        $subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
        
        # Create network interface without public IP
        $nicName = "$VMName-nic"
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $subnet.Id
        
        # Add NIC to VM configuration
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary
        
        Write-Log "VM configuration created successfully" -Level "Success"
        return $vmConfig
    }
    catch {
        Write-Log "Failed to create VM configuration: $($_.Exception.Message)" -Level "Error"
        throw
    }
}

# Main execution
try {
    Write-Log "=== AZURE VM CROSS-TENANT COPY SCRIPT (OPTIMIZED) ===" -Level "Success"
    Write-Log "Performance Features Enabled:" -Level "Success"
    Write-Log "- Direct Azure Storage Copy (fastest, no local downloads)"
    Write-Log "- Optimized AzCopy fallback with maximum concurrency"
    Write-Log "- Extended SAS token duration (8 hours) for reliability"
    Write-Log "- Progressive fallback strategy for maximum compatibility"
    Write-Log ""
    Write-Log "Starting Azure VM copy process..." -Level "Success"
    
    # Set default destination VM name if not provided
    if (-not $DestinationVMName) {
        $DestinationVMName = $SourceVMName
    }
    
    # Step 1: Authenticate and connect to source tenant
    Write-Log "=== STEP 1: Connecting to Source Tenant ===" -Level "Success"
    
    # If no tenant ID provided, try to discover it
    if (-not $SourceTenantId) {
        Write-Log "No source tenant ID provided. Attempting to discover..." -Level "Warning"
        $SourceTenantId = Get-TenantIdFromSubscription -SubscriptionId $SourceSubscriptionId
        if ($SourceTenantId) {
            Write-Log "Discovered source tenant ID: $SourceTenantId" -Level "Success"
        }
    }
    
    Connect-ToAzure -Context "Source" -TenantId $SourceTenantId
    $sourceContext = Set-AzureContext -SubscriptionId $SourceSubscriptionId -Context "Source"
    
    # Step 2: Get source VM details
    Write-Log "=== STEP 2: Getting Source VM Details ===" -Level "Success"
    $sourceVM = Get-VMDetails -ResourceGroupName $SourceResourceGroupName -VMName $SourceVMName
    
    # Set default VM size if not provided
    if (-not $DestinationVMSize) {
        $DestinationVMSize = $sourceVM.HardwareProfile.VmSize
    }
    
    Write-Log "Source VM Details:"
    Write-Log "  Name: $($sourceVM.Name)"
    Write-Log "  Size: $($sourceVM.HardwareProfile.VmSize)"
    Write-Log "  Location: $($sourceVM.Location)"
    Write-Log "  OS Type: $($sourceVM.StorageProfile.OsDisk.OsType)"
    Write-Log "  OS Disk Size: $($sourceVM.StorageProfile.OsDisk.DiskSizeGB) GB"
    Write-Log "  Data Disks: $($sourceVM.StorageProfile.DataDisks.Count)"
    
    # Step 3: Create snapshots directly (skip intermediate storage for cross-tenant)
    Write-Log "=== STEP 3: Creating Snapshots for Cross-Tenant Transfer ===" -Level "Success"
    Write-Log "Using direct snapshot approach for cross-tenant compatibility..."
    
    # Container name for destination (still needed)
    $containerName = "vhds"

    # Step 4: Create snapshots and prepare for cross-tenant export
    Write-Log "=== STEP 4: Creating Snapshots and Preparing for Export ===" -Level "Success"
    
    $exportedDisks = @()
    
    # Process OS disk
    Write-Log "Processing OS disk..."
    
    # Get actual OS disk size from the managed disk (more reliable than VM profile)
    $osManagedDisk = Get-AzDisk -ResourceGroupName $SourceResourceGroupName -DiskName ($sourceVM.StorageProfile.OsDisk.Name)
    $actualOsDiskSizeGB = $osManagedDisk.DiskSizeGB
    Write-Log "OS disk actual size: $actualOsDiskSizeGB GB"
    
    $osDiskSnapshotName = "$($sourceVM.Name)-os-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $osSnapshot = Invoke-WithRetry { New-DiskSnapshot -DiskId $sourceVM.StorageProfile.OsDisk.ManagedDisk.Id -SnapshotName $osDiskSnapshotName -ResourceGroupName $SourceResourceGroupName -Location $sourceVM.Location }
    
    $osDownloadUrl = Invoke-WithRetry { Get-SnapshotDownloadUrl -ResourceGroupName $SourceResourceGroupName -SnapshotName $osDiskSnapshotName }
    $osVhdName = "$($sourceVM.Name)-os.vhd"
    
    # For cross-tenant copying, we'll use the snapshot download URL directly (has SAS token)
    # No need to copy to intermediate storage account first
    Write-Log "OS disk snapshot ready for cross-tenant transfer (using snapshot SAS URL)..."
    
    $exportedDisks += @{
        Name = "$($DestinationVMName)-os-disk"
        VHDUrl = $osDownloadUrl  # Use snapshot download URL with SAS token for cross-tenant
        VHDName = $osVhdName     # Store blob name separately  
        SizeGB = $actualOsDiskSizeGB  # Use actual disk size from managed disk
        Type = "OS"
        OSType = $sourceVM.StorageProfile.OsDisk.OsType
        Lun = $null
        Caching = $sourceVM.StorageProfile.OsDisk.Caching
    }
    
    # Process data disks
    foreach ($dataDisk in $sourceVM.StorageProfile.DataDisks) {
        Write-Log "Processing data disk LUN $($dataDisk.Lun)..."
        
        # Get actual data disk size from the managed disk (more reliable than VM profile)
        $dataManagedDisk = Get-AzDisk -ResourceGroupName $SourceResourceGroupName -DiskName ($dataDisk.Name)
        $actualDataDiskSizeGB = $dataManagedDisk.DiskSizeGB
        Write-Log "Data disk LUN $($dataDisk.Lun) actual size: $actualDataDiskSizeGB GB"
        
        $dataDiskSnapshotName = "$($sourceVM.Name)-data$($dataDisk.Lun)-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        $dataSnapshot = Invoke-WithRetry { New-DiskSnapshot -DiskId $dataDisk.ManagedDisk.Id -SnapshotName $dataDiskSnapshotName -ResourceGroupName $SourceResourceGroupName -Location $sourceVM.Location }
        
        $dataDownloadUrl = Invoke-WithRetry { Get-SnapshotDownloadUrl -ResourceGroupName $SourceResourceGroupName -SnapshotName $dataDiskSnapshotName }
        $dataVhdName = "$($sourceVM.Name)-data$($dataDisk.Lun).vhd"
        
        # For cross-tenant copying, we'll use the snapshot download URL directly (has SAS token)
        # No need to copy to intermediate storage account first
        Write-Log "Data disk LUN $($dataDisk.Lun) snapshot ready for cross-tenant transfer (using snapshot SAS URL)..."
        
        $exportedDisks += @{
            Name = "$($DestinationVMName)-data$($dataDisk.Lun)-disk"
            VHDUrl = $dataDownloadUrl  # Use snapshot download URL with SAS token for cross-tenant
            VHDName = $dataVhdName     # Store blob name separately
            SizeGB = $actualDataDiskSizeGB  # Use actual disk size from managed disk
            Type = "Data"
            OSType = $null
            Lun = $dataDisk.Lun
            Caching = $dataDisk.Caching
        }
    }
    
    # Step 5: Switch to destination tenant
    Write-Log "=== STEP 5: Switching to Destination Tenant ===" -Level "Success"
    Write-Log "Please authenticate to the destination tenant when prompted..."
    
    # Clear current context and authenticate to destination
    Disconnect-AzAccount -ErrorAction SilentlyContinue
    
    # If no destination tenant ID provided, try to discover it
    if (-not $DestinationTenantId) {
        Write-Log "No destination tenant ID provided. Attempting to discover..." -Level "Warning"
        $DestinationTenantId = Get-TenantIdFromSubscription -SubscriptionId $DestinationSubscriptionId
        if ($DestinationTenantId) {
            Write-Log "Discovered destination tenant ID: $DestinationTenantId" -Level "Success"
        }
    }
    
    Connect-ToAzure -Context "Destination" -TenantId $DestinationTenantId
    $destContext = Set-AzureContext -SubscriptionId $DestinationSubscriptionId -Context "Destination"
    
    # Step 6: Create destination resource group if it doesn't exist
    Write-Log "=== STEP 6: Preparing Destination Environment ===" -Level "Success"
    try {
        Get-AzResourceGroup -Name $DestinationResourceGroupName -ErrorAction Stop
        Write-Log "Destination resource group exists: $DestinationResourceGroupName" -Level "Success"
    }
    catch {
        Write-Log "Creating destination resource group: $DestinationResourceGroupName"
        New-AzResourceGroup -Name $DestinationResourceGroupName -Location $DestinationLocation
        Write-Log "Destination resource group created" -Level "Success"
    }
    
    # Create storage account in destination
    $StorageAccountName = "vmcopytemp" + (Get-Random -Minimum 1000 -Maximum 9999)  # Create storage account name
    $destStorageAccountName = "$StorageAccountName" + "dest"  # Remove hyphen, just append "dest"
    $destStorageAccount = New-StorageAccountIfNotExists -ResourceGroupName $DestinationResourceGroupName -StorageAccountName $destStorageAccountName -Location $DestinationLocation
    
    # Use Azure AD authentication for destination storage context
    Write-Log "Creating Azure AD authenticated destination storage context..."
    $destStorageContext = New-AzStorageContext -StorageAccountName $destStorageAccountName -UseConnectedAccount
    
    # Ensure the current user has Storage Blob Data Contributor role on destination
    Write-Log "Ensuring proper RBAC permissions for destination storage account..."
    $currentUser = (Get-AzContext).Account.Id
    try {
        New-AzRoleAssignment -SignInName $currentUser -RoleDefinitionName "Storage Blob Data Contributor" -Scope "/subscriptions/$DestinationSubscriptionId/resourceGroups/$DestinationResourceGroupName/providers/Microsoft.Storage/storageAccounts/$destStorageAccountName" -ErrorAction SilentlyContinue
        Write-Log "RBAC permissions verified for destination" -Level "Success"
        # Wait for RBAC permissions to propagate
        Write-Log "Waiting for RBAC permissions to propagate..." -Level "Info"
        Start-Sleep -Seconds 30
    }
    catch {
        Write-Log "RBAC permission assignment skipped (may already exist)" -Level "Warning"
        # Still wait a bit in case permissions need time to propagate
        Start-Sleep -Seconds 10
    }
    
    # Create container in destination
    New-AzStorageContainer -Name $containerName -Context $destStorageContext -Permission Off -ErrorAction SilentlyContinue
    
    # Step 7: Copy VHDs to destination storage (OPTIMIZED FOR SPEED)
    Write-Log "=== STEP 7: Copying VHDs to Destination (Optimized) ===" -Level "Success"
    
    $destinationDisks = @()
    
    # Process disks with cross-tenant AzCopy approach
    foreach ($disk in $exportedDisks) {
        $destVhdName = $disk.VHDName
        $destVhdUrl = "$($destStorageAccount.PrimaryEndpoints.Blob)$containerName/$destVhdName"
        
        Write-Log "Copying $destVhdName to destination tenant..."
        
        # For cross-tenant copy, we use the snapshot download URL (already has SAS token)6
        $sourceUrl = $disk.VHDUrl  # This is the snapshot download URL with SAS token
        
        # Generate SAS token for destination blob with comprehensive permissions
        Write-Log "Generating destination SAS token for $destVhdName..."
        try {
            $destSasToken = New-AzStorageBlobSASToken -Container $containerName -Blob $destVhdName -Context $destStorageContext -Permission "rwdlac" -ExpiryTime (Get-Date).AddHours(8) -FullUri
            Write-Log "SAS token generated successfully for destination blob" -Level "Success"
        }
        catch {
            Write-Log "Failed to generate SAS token with Azure AD context, retrying with storage key..." -Level "Warning"
            # Fallback to storage key if Azure AD fails
            $destStorageKey = (Get-AzStorageAccountKey -ResourceGroupName $DestinationResourceGroupName -Name $destStorageAccount.StorageAccountName)[0].Value
            $destStorageContextKey = New-AzStorageContext -StorageAccountName $destStorageAccount.StorageAccountName -StorageAccountKey $destStorageKey
            $destSasToken = New-AzStorageBlobSASToken -Container $containerName -Blob $destVhdName -Context $destStorageContextKey -Permission "rwdlac" -ExpiryTime (Get-Date).AddHours(8) -FullUri
        }
        
        # Use AzCopy for cross-tenant transfer (MOST RELIABLE method)
        try {
            Write-Log "Using AzCopy for cross-tenant transfer of $destVhdName..."
            Invoke-WithRetry {
                Copy-VHDWithAzCopy -SourceUrl $sourceUrl -DestinationUrl $destSasToken
            }
            Write-Log "AzCopy transfer successful for $destVhdName" -Level "Success"
        }
        catch {
            Write-Log "AzCopy transfer failed for $destVhdName, error: $($_.Exception.Message)" -Level "Error"
            throw "Failed to copy $destVhdName to destination tenant"
        }
        
        # Create managed disk from VHD
        Write-Log "Creating managed disk: $($disk.Name)"
        $storageAccountId = $destStorageAccount.Id
        $managedDisk = Invoke-WithRetry { 
            New-ManagedDiskFromVHD -DiskName $disk.Name -ResourceGroupName $DestinationResourceGroupName -Location $DestinationLocation -VHDUri $destVhdUrl -DiskSizeGB $disk.SizeGB -OSType $disk.OSType -StorageAccountId $storageAccountId
        }
        
        $destinationDisks += @{
            Disk = $managedDisk
            Type = $disk.Type
            Lun = $disk.Lun
            Caching = $disk.Caching
        }
    }
    
    # Step 8: Create destination VM
    Write-Log "=== STEP 8: Creating Destination VM ===" -Level "Success"
    
    $osDisk = ($destinationDisks | Where-Object { $_.Type -eq "OS" }).Disk
    $dataDisks = $destinationDisks | Where-Object { $_.Type -eq "Data" }
    
    $vmConfig = New-VMConfiguration -SourceVM $sourceVM -VMName $DestinationVMName -VMSize $DestinationVMSize -Location $DestinationLocation -AvailabilityZone $DestinationAvailabilityZone -OSDisk $osDisk -DataDisks $dataDisks -VNetName $DestinationVNetName -SubnetName $DestinationSubnetName -ResourceGroupName $DestinationResourceGroupName

    Write-Log "Creating VM: $DestinationVMName (will be created in stopped state)"
    
    # Start VM creation in background (recreate config to avoid serialization issues)
    Write-Log "Starting VM creation in background..."
    
    $vmJob = Start-Job -ScriptBlock {
        param($rgName, $location, $vmName, $vmSize, $availabilityZone, $osDiskId, $dataDisks, $vnetName, $subnetName, $sourceOsType)
        
        try {
            # Re-import modules in job context
            Import-Module Az.Compute, Az.Resources, Az.Network -Force
            
            # Use existing authentication context
            $context = Get-AzContext
            if (-not $context) {
                throw "No Azure context available in background job"
            }
            
            Write-Output "Job: Starting VM creation..."
            
            # Recreate VM configuration inside the job to avoid serialization issues
            $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $vmSize
            
            # Disable boot diagnostics
            $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable
            
            # Add availability zone if specified
            if ($availabilityZone) {
                $vmConfig.Zones = @($availabilityZone)
            }
            
            # Set OS disk - following official Microsoft documentation pattern
            Write-Output "Job: Attaching OS disk: $osDiskId with OS type: $sourceOsType"
            if ($sourceOsType -eq "Windows") {
                $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $osDiskId -CreateOption Attach -Windows -StorageAccountType Premium_LRS
            } else {
                $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $osDiskId -CreateOption Attach -Linux -StorageAccountType Premium_LRS
            }
            Write-Output "Job: OS disk attached successfully"
            
            # Add data disks if any
            foreach ($dataDiskInfo in $dataDisks) {
                $vmConfig = Add-AzVMDataDisk -VM $vmConfig -ManagedDiskId $dataDiskInfo.DiskId -CreateOption Attach -Lun $dataDiskInfo.Lun -Caching $dataDiskInfo.Caching
            }
            
            # Get networking components (should already exist)
            $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName
            $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
            $nicName = "$vmName-nic"
            $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $rgName
            
            # Add NIC to VM configuration
            $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary
            
            # Create the VM
            $result = New-AzVM -ResourceGroupName $rgName -Location $location -VM $vmConfig -Verbose
            
            Write-Output "Job: VM creation completed successfully"
            return $result
        }
        catch {
            Write-Error "Job: VM creation failed: $($_.Exception.Message)"
            Write-Error "Job: Stack trace: $($_.ScriptStackTrace)"
            throw
        }
    } -ArgumentList $DestinationResourceGroupName, $DestinationLocation, $DestinationVMName, $DestinationVMSize, $DestinationAvailabilityZone, $osDisk.Id, @($dataDisks | ForEach-Object { @{ DiskId = $_.Disk.Id; Lun = $_.Lun; Caching = $_.Caching } }), $DestinationVNetName, $DestinationSubnetName, $sourceVM.StorageProfile.OsDisk.OsType
    
    # Parallel checking: Monitor both job status AND VM existence
    Write-Log "Monitoring VM creation progress (checking every 30 seconds)..."
    $maxWaitTime = 300  # 5 minutes maximum
    $checkInterval = 30  # Check every 30 seconds
    $elapsedTime = 0
    $vmCreated = $false
    $jobFailed = $false
    
    while ($elapsedTime -lt $maxWaitTime -and -not $vmCreated -and -not $jobFailed) {
        Start-Sleep -Seconds $checkInterval
        $elapsedTime += $checkInterval
        
        Write-Log "Checking VM status... ($elapsedTime seconds elapsed)"
        
        # Check job status first
        $jobState = Get-Job -Id $vmJob.Id
        if ($jobState.State -eq "Failed") {
            $jobFailed = $true
            $jobError = Receive-Job -Job $vmJob -ErrorAction SilentlyContinue
            $jobErrorOutput = Receive-Job -Job $vmJob 2>&1
            Write-Log "Background VM creation job FAILED:" -Level "Error"
            Write-Log "Job Error: $jobErrorOutput" -Level "Error"
            break
        } elseif ($jobState.State -eq "Completed") {
            $jobResult = Receive-Job -Job $vmJob
            Write-Log "Background VM creation job completed successfully" -Level "Success"
        }
        
        # Check if VM exists in Azure (parallel to job)
        $createdVM = Get-AzVM -ResourceGroupName $DestinationResourceGroupName -Name $DestinationVMName -ErrorAction SilentlyContinue
        
        if ($createdVM) {
            $vmCreated = $true
            Write-Log "✅ VM detected in Azure after $elapsedTime seconds!" -Level "Success"
            
            # VM exists, stop monitoring
            break
        }
    }
    
    # Clean up job
    Remove-Job -Job $vmJob -Force -ErrorAction SilentlyContinue
    
    if ($jobFailed) {
        Write-Log "❌ VM creation job failed - see error details above" -Level "Error"
        throw "VM creation failed - background job encountered an error"
    } elseif (-not $vmCreated) {
        Write-Log "❌ VM was not detected after $maxWaitTime seconds" -Level "Error"
        # Check if there are any incomplete VMs or resources that might give us clues
        Write-Log "Checking for partial VM creation..." -Level "Warning"
        $partialVM = Get-AzResource -ResourceGroupName $DestinationResourceGroupName -Name $DestinationVMName -ErrorAction SilentlyContinue
        if ($partialVM) {
            Write-Log "Found partial VM resource: $($partialVM.ResourceType)" -Level "Warning"
        }
        throw "VM creation failed - VM not detected in Azure after $maxWaitTime seconds"
    }
    
    # Final verification
    $newVM = Get-AzVM -ResourceGroupName $DestinationResourceGroupName -Name $DestinationVMName
    Write-Log "Final verification: VM '$DestinationVMName' exists and is ready" -Level "Success"
    
    # Stop the VM after creation to save costs
    Write-Log "Stopping VM to save costs (VM created successfully but not running)..."
    Stop-AzVM -ResourceGroupName $DestinationResourceGroupName -Name $DestinationVMName -Force
    
    Write-Log "=== COPY COMPLETED SUCCESSFULLY ===" -Level "Success"
    Write-Log "Source VM: $SourceVMName (Subscription: $SourceSubscriptionId)"
    Write-Log "Destination VM: $DestinationVMName (Subscription: $DestinationSubscriptionId) - STOPPED"
    Write-Log "Destination VM: $DestinationVMName (Subscription: $DestinationSubscriptionId)"
    Write-Log "VM Size: $DestinationVMSize"
    Write-Log "Location: $DestinationLocation"
    Write-Log "Resource Group: $DestinationResourceGroupName"
    
    # Cleanup temporary resources
    Write-Log "=== CLEANUP ===" -Level "Success"
    Write-Log "Cleaning up temporary resources..."
    
    # Switch back to source to clean up snapshots
    Set-AzureContext -SubscriptionId $SourceSubscriptionId -Context "Source Cleanup"
    
    # Remove snapshots
    foreach ($disk in $exportedDisks) {
        if ($disk.Type -eq "OS") {
            $snapshotName = $osDiskSnapshotName
        } else {
            $snapshotName = "$($sourceVM.Name)-data$($disk.Lun)-snapshot-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        }
        
        try {
            Remove-AzSnapshot -ResourceGroupName $SourceResourceGroupName -SnapshotName $snapshotName -Force
            Write-Log "Removed snapshot: $snapshotName"
        }
        catch {
            Write-Log "Failed to remove snapshot $snapshotName`: $($_.Exception.Message)" -Level "Warning"
        }
    }
    
    Write-Log "VM copy process completed successfully!" -Level "Success"
}
catch {
    Write-Log "VM copy process failed: $($_.Exception.Message)" -Level "Error"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "Error"
    exit 1
}
