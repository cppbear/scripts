# Configuration Parameters
$env:WSL_UTF8 = 1
$backupDir = "E:\WSLBackups"   # Root backup directory
$daysToKeep = 5                # Keep backups newer than X days
$keepLast = 3                  # Keep last Y backups per instance
$excludedDistros = @("docker-desktop", "docker-desktop-data")  # Excluded distributions

$logFile = Join-Path -Path $backupDir -ChildPath "backup.log"
Start-Transcript -Path "$logFile" -Append

# Create root backup directory if missing
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

# Get WSL distributions list
$distros = wsl --list --quiet | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_) -and
    $excludedDistros -notcontains $_
}

# Backup Process
foreach ($distro in $distros) {
    # Create instance-specific directory
    $instanceDir = Join-Path -Path $backupDir -ChildPath $distro
    if (-not (Test-Path $instanceDir)) {
        New-Item -ItemType Directory -Path $instanceDir -Force | Out-Null
    }

    # Generate timestamped filename
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path -Path $instanceDir -ChildPath "${distro}_$timestamp.tar.gz"

    # Execute WSL export
    Write-Host "[$distro] Creating backup: $backupFile"
    try {
        wsl --export "$distro" "$backupFile" --format tar.gz
    }
    catch {
        Write-Host "Error exporting $distro : $_"
        continue
    }

    # Verify backup creation
    if (Test-Path $backupFile) {
        Write-Host "✓ Backup succeeded: $backupFile"
    }
    else {
        Write-Host "✗ Backup failed: $distro"
    }
}

# Cleanup Process
Get-ChildItem $backupDir -Directory | ForEach-Object {
    $instanceDir = $_.FullName
    $instanceName = $_.Name

    # Get all backups for this instance
    $allBackups = Get-ChildItem $instanceDir -Filter *.tar.gz |
    Sort-Object LastWriteTime -Descending

    # Skip if no backups found
    if (-not $allBackups) { return }

    # Retention Policy 1: Keep most recent Y backups
    $latestToKeep = $allBackups | Select-Object -First $keepLast

    # Retention Policy 2: Keep backups within X days
    $dateThreshold = (Get-Date).AddDays(-$daysToKeep)
    $recentToKeep = $allBackups | Where-Object {
        $_.LastWriteTime -ge $dateThreshold
    }

    # Combine policies and remove duplicates
    $combined = @($latestToKeep) + @($recentToKeep)
    $protectedBackups = $combined |
        Sort-Object -Property FullName -Unique |
        Sort-Object LastWriteTime -Descending

    # Identify obsolete backups
    $obsoleteBackups = $allBackups | Where-Object {
        $protectedBackups -notcontains $_
    }

    # Remove obsolete backups
    if ($obsoleteBackups) {
        Write-Host "Cleaning up [$instanceName]:"
        $obsoleteBackups | ForEach-Object {
            Write-Host "• Removing: $($_.Name)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        Write-Host ""
    }
}

Stop-Transcript
