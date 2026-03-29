#Requires -Version 5.1

param(
    [switch]$Silent,
    [switch]$Overwrite,
    [string]$Product       = '',
    [Parameter(Position=0)]
    [string]$Install    = '',
    [string]$Commit        = '',
    [string]$ProjectFolder  = '',
    [string]$WorkspacePath  = '',
    [switch]$BuildOnly,
    [switch]$Uninstall,
    [switch]$ListProducts,
    [switch]$List,
    [switch]$Init,
    [switch]$Help
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================================
# CONSTANTS
# ==============================================================================

$BlocksRepositoryUrl = 'https://github.com/lminuti/blocks-repository'
$ScriptName          = 'blocks'

# ==============================================================================
# DELPHI VERSION REGISTRY MAP
# ==============================================================================

# Maps BDS registry subkey (e.g. "23.0") to an internal version name
$BdsToVersionName = @{
    '14.0' = 'delphixe6'
    '15.0' = 'delphixe7'
    '16.0' = 'delphixe8'
    '17.0' = 'delphi10'
    '18.0' = 'delphiberlin'
    '19.0' = 'delphitokyo'
    '20.0' = 'delphirio'
    '21.0' = 'delphisydney'
    '22.0' = 'delphi11'
    '23.0' = 'delphi12'
    '37.0' = 'delphi13'
}

# Ordered list of version names (ascending) — used for "greatest lower bound" matching
$VersionOrder = @(
    'delphixe6', 'delphixe7', 'delphixe8',
    'delphi10',
    'delphiberlin', 'delphitokyo', 'delphirio', 'delphisydney',
    'delphi11', 'delphi12', 'delphi13'
)

# Human-readable display names
$VersionDisplayNames = @{
    'delphixe6'    = 'Delphi XE6'
    'delphixe7'    = 'Delphi XE7'
    'delphixe8'    = 'Delphi XE8'
    'delphi10'     = 'Delphi 10 Seattle'
    'delphiberlin' = 'Delphi 10.1 Berlin'
    'delphitokyo'  = 'Delphi 10.2 Tokyo'
    'delphirio'    = 'Delphi 10.3 Rio'
    'delphisydney' = 'Delphi 10.4 Sydney'
    'delphi11'     = 'Delphi 11 Alexandria'
    'delphi12'     = 'Delphi 12 Athens'
    'delphi13'     = 'Delphi 13'
}

# ==============================================================================
# FUNCTIONS
# ==============================================================================

function Show-Banner {
    param([string]$AppName, [string]$Description)

    # Box-drawing chars via code points (avoids source encoding issues)
    $tl = [char]0x256D  # curved top-left:    ╭
    $tr = [char]0x256E  # curved top-right:   ╮
    $bl = [char]0x2570  # curved bottom-left: ╰
    $br = [char]0x256F  # curved bottom-right:╯
    $hz = [char]0x2500  # horizontal:         ─
    $vt = [char]0x2502  # vertical:           │
    $ml = [char]0x251C  # mid-left:           ├
    $mr = [char]0x2524  # mid-right:          ┤
    $dm = [char]0x25C6  # diamond:            ◆
    $ar = [char]0x25B8  # arrow:              ▸

    $w = 50

    function ln([string]$text) {
        ($vt + $text).PadRight($w + 1) + $vt
    }

    $line = "$hz" * $w
    $top  = "$tl" + $line + "$tr"
    $sep  = "$ml" + $line + "$mr"
    $bot  = "$bl" + $line + "$br"

    Write-Host ''
    Write-Host $top -ForegroundColor Cyan
    Write-Host (ln '  ____  _     ___   ____  _  __ ____   ') -ForegroundColor Cyan
    Write-Host (ln ' | __ )| |   / _ \ / ___|| |/ // ___|  ') -ForegroundColor Cyan
    Write-Host (ln " |  _ \| |  | | | | |    | ' / \___ \  ") -ForegroundColor Cyan
    Write-Host (ln ' | |_) | |__| |_| | |___ | . \  ___) | ') -ForegroundColor Cyan
    Write-Host (ln ' |____/|_____\___/ \____||_|\_\|____/   ') -ForegroundColor Cyan
    Write-Host $sep -ForegroundColor DarkCyan
    Write-Host (ln "  $dm  Delphi Package Installer") -ForegroundColor DarkCyan

    if (-not [string]::IsNullOrWhiteSpace($AppName)) {
        Write-Host $sep -ForegroundColor DarkCyan
        Write-Host (ln "  Package  $ar  $AppName") -ForegroundColor White
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            Write-Host (ln "  About    $ar  $Description") -ForegroundColor Gray
        }
    }

    Write-Host $bot -ForegroundColor Cyan
    Write-Host ''
}

function Test-DelphiRunning {
    $delphiProcesses = Get-Process -Name 'bds' -ErrorAction SilentlyContinue
    if (-not $delphiProcesses) { return }

    Write-Host ""
    Write-Host "WARNING: The following Delphi instance(s) are currently open:" -ForegroundColor Yellow
    foreach ($p in $delphiProcesses) {
        Write-Host "  - $($p.MainWindowTitle) (PID $($p.Id))" -ForegroundColor Yellow
    }
    Write-Host "  Please close Delphi before continuing, or the installation may not work correctly." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press ENTER to continue anyway, or close Delphi and then press ENTER"
}


function Get-VersionRank {
    param([string]$VersionName, [string]$BdsVersion)
    $idx = [Array]::IndexOf($VersionOrder, $VersionName)
    if ($idx -ge 0) { return $idx }
    # Unknown version: rank beyond all known ones, ordered by BDS version number
    return $VersionOrder.Count + [int]([double]$BdsVersion * 10)
}

function Get-InstalledDelphiVersions {
    $regPaths = @(
        'HKLM:\SOFTWARE\Embarcadero\BDS',
        'HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS',
        'HKCU:\SOFTWARE\Embarcadero\BDS'
    )

    $seenBds = @{}
    $found   = @()

    foreach ($regPath in $regPaths) {
        if (-not (Test-Path $regPath)) { continue }

        foreach ($key in (Get-ChildItem $regPath -ErrorAction SilentlyContinue)) {
            $bdsKey = $key.PSChildName
            if ($seenBds.ContainsKey($bdsKey)) { continue }
            $seenBds[$bdsKey] = $true

            $rootDir = (Get-ItemProperty -Path $key.PSPath -Name 'RootDir' -ErrorAction SilentlyContinue).RootDir
            if (-not $rootDir -or -not (Test-Path $rootDir)) { continue }

            if ($BdsToVersionName.ContainsKey($bdsKey)) {
                $versionName = $BdsToVersionName[$bdsKey]
                $displayName = $VersionDisplayNames[$versionName]
            }
            else {
                $versionName = "bds_$bdsKey"
                $displayName = "Delphi (BDS $bdsKey)"
            }

            $found += [PSCustomObject]@{
                BdsVersion  = $bdsKey
                VersionName = $versionName
                DisplayName = $displayName
                RootDir     = $rootDir
            }
        }
    }

    # Sort descending (most recent first = default)
    $found = $found | Sort-Object { Get-VersionRank -VersionName $_.VersionName -BdsVersion $_.BdsVersion } -Descending
    return $found
}

function Select-DelphiVersion {
    param([array]$InstalledVersions)

    if ($InstalledVersions.Count -eq 0) {
        throw "No Delphi version found in the registry."
    }

    # --product: match by display name or internal version name (case-insensitive)
    if (-not [string]::IsNullOrWhiteSpace($script:Product)) {
        $match = $InstalledVersions | Where-Object {
            $_.DisplayName -ieq $script:Product -or $_.VersionName -ieq $script:Product
        } | Select-Object -First 1
        if ($null -eq $match) {
            throw "Product '$($script:Product)' not found among installed Delphi versions."
        }
        return $match
    }

    Write-Host "Installed Delphi versions:" -ForegroundColor Green
    for ($i = 0; $i -lt $InstalledVersions.Count; $i++) {
        $marker = if ($i -eq 0) { " (default)" } else { "" }
        Write-Host ("  [{0}] {1}{2}" -f ($i + 1), $InstalledVersions[$i].DisplayName, $marker)
    }
    Write-Host ""

    $inputStr = Read-Host "Select version [1-$($InstalledVersions.Count)] (ENTER for default)"
    if ([string]::IsNullOrWhiteSpace($inputStr)) { return $InstalledVersions[0] }

    $index = 0
    if ([int]::TryParse($inputStr, [ref]$index) -and $index -ge 1 -and $index -le $InstalledVersions.Count) {
        return $InstalledVersions[$index - 1]
    }

    Write-Host "Invalid selection, using default." -ForegroundColor Yellow
    return $InstalledVersions[0]
}

function Get-PackageFolder {
    param(
        [string]   $InstalledVersionName,
        [string]   $InstalledBdsVersion,
        [hashtable]$PackageFolders
    )

    $installedRank = Get-VersionRank -VersionName $InstalledVersionName -BdsVersion $InstalledBdsVersion

    $bestKey  = $null
    $bestRank = -1

    foreach ($key in $PackageFolders.Keys) {
        $baseKey  = $key.TrimEnd('+')
        $keyRank  = [Array]::IndexOf($VersionOrder, $baseKey)
        if ($keyRank -lt 0) { continue }   # config keys must be known versions

        if ($keyRank -le $installedRank -and $keyRank -gt $bestRank) {
            $bestRank = $keyRank
            $bestKey  = $key
        }
    }

    if ($null -eq $bestKey) {
        throw "No compatible package folder found for '$InstalledVersionName'. Delphi version too old?"
    }

    return $PackageFolders[$bestKey]
}

function Get-MsBuildPath {
    # 1. Already on PATH
    $cmd = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. .NET Framework locations (used by Delphi bat files)
    $candidates = @(
        "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe",
        "$env:SystemRoot\Microsoft.NET\Framework\v3.5\MSBuild.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }

    # 3. MSBuild registry (ToolsVersions)
    $tbKey = 'HKLM:\SOFTWARE\Microsoft\MSBuild\ToolsVersions\4.0'
    if (Test-Path $tbKey) {
        $toolsPath = (Get-ItemProperty $tbKey -Name MSBuildToolsPath -ErrorAction SilentlyContinue).MSBuildToolsPath
        if ($toolsPath) {
            $exe = Join-Path $toolsPath 'MSBuild.exe'
            if (Test-Path $exe) { return $exe }
        }
    }

    throw "MSBuild not found. Please install .NET Framework SDK or Visual Studio Build Tools."
}

function Test-PlatformInstalled {
    param(
        [string]$BdsVersion,
        [string]$Platform
    )

    $regPaths = @(
        "HKLM:\SOFTWARE\WOW6432Node\Embarcadero\BDS\$BdsVersion\Library\$Platform",
        "HKLM:\SOFTWARE\Embarcadero\BDS\$BdsVersion\Library\$Platform",
        "HKCU:\SOFTWARE\Embarcadero\BDS\$BdsVersion\Library\$Platform"
    )

    foreach ($path in $regPaths) {
        if (Test-Path $path) { return $true }
    }
    return $false
}

function Update-LibraryPaths {
    param(
        [string]       $BdsVersion,
        [string]       $Platform,
        [string]       $ProjectDir,
        [PSCustomObject]$PlatformConfig
    )

    $regPath = "HKCU:\Software\Embarcadero\BDS\$BdsVersion\Library\$Platform"

    $mappings = @(
        @{ JsonProp = 'sourcePath';   RegValue = 'Search Path'    },
        @{ JsonProp = 'browsingPath'; RegValue = 'Browsing Path'  },
        @{ JsonProp = 'debugDCUPath'; RegValue = 'Debug DCU Path' }
    )

    foreach ($mapping in $mappings) {
        $relativePaths = $PlatformConfig.$($mapping.JsonProp)
        if (-not $relativePaths -or $relativePaths.Count -eq 0) { continue }

        $newPaths = $relativePaths | ForEach-Object { Join-Path $ProjectDir $_ }

        $existing     = (Get-ItemProperty -Path $regPath -Name $mapping.RegValue -ErrorAction SilentlyContinue).$($mapping.RegValue)
        $existingList = if ($existing) { $existing.Split(';') | Where-Object { $_ -ne '' } } else { @() }

        $added = @()
        foreach ($path in $newPaths) {
            if ($existingList -notcontains $path) {
                $existingList += $path
                $added        += $path
            }
        }

        if ($added.Count -gt 0) {
            Set-ItemProperty -Path $regPath -Name $mapping.RegValue -Value ($existingList -join ';')
            foreach ($p in $added) {
                Write-Host "    + [$($mapping.RegValue)] $p" -ForegroundColor DarkGray
            }
        }
    }
}

function Invoke-PackageBuild {
    param(
        [PSCustomObject]$DelphiVersion,
        [string]        $ProjectDir,
        [string]        $PackageFolder,
        [array]          $Packages,
        [PSCustomObject] $SupportedPlatforms
    )

    $bdsDir       = $DelphiVersion.RootDir.TrimEnd('\')
    $bdsCommonDir = "$env:PUBLIC\Documents\Embarcadero\Studio\$($DelphiVersion.BdsVersion)"
    $msbuild      = Get-MsBuildPath
    $packagesPath = Join-Path $ProjectDir "packages\$PackageFolder"

    # Set Delphi environment variables for child processes
    $env:BDS          = $bdsDir
    $env:BDSINCLUDE   = "$bdsDir\include"
    $env:BDSCOMMONDIR = $bdsCommonDir
    $env:LANGDIR      = 'EN'
    $env:PLATFORM     = ''

    # Prepend BDS bin dirs to PATH (avoid duplicates)
    foreach ($bin in @("$bdsDir\bin64", "$bdsDir\bin")) {
        if ($env:PATH -notlike "*$bin*") {
            $env:PATH = "$bin;$env:PATH"
        }
    }

    $platformEntries = $SupportedPlatforms.PSObject.Properties

    # Verify all platforms are installed before starting
    foreach ($entry in $platformEntries) {
        if (-not (Test-PlatformInstalled -BdsVersion $DelphiVersion.BdsVersion -Platform $entry.Name)) {
            throw "Platform '$($entry.Name)' is not installed for $($DelphiVersion.DisplayName)."
        }
    }

    $platformNames = ($platformEntries | ForEach-Object { $_.Name }) -join ', '

    Write-Host "Compiling packages..." -ForegroundColor Cyan
    Write-Host "  MSBuild   : $msbuild"
    Write-Host "  BDS       : $bdsDir"
    Write-Host "  Packages  : $packagesPath"
    Write-Host "  Platforms : $platformNames"
    Write-Host ""

    foreach ($entry in $platformEntries) {
        $platform       = $entry.Name
        $platformConfig = $entry.Value

        Write-Host "  [$platform]" -ForegroundColor DarkCyan

        foreach ($pkg in $Packages) {
            $dproj = Join-Path $packagesPath "$($pkg.name).dproj"

            if (-not (Test-Path $dproj)) {
                throw "Package not found: $dproj"
            }

            Write-Host "    Building $($pkg.name) [$($pkg.type -join ', ')]..." -NoNewline

            $output = & $msbuild $dproj /t:Make /p:config=Release /p:platform=$platform /nologo /v:quiet 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host " OK" -ForegroundColor Green
            }
            else {
                Write-Host " FAILED" -ForegroundColor Red
                $output | Where-Object { $_ -match '\berror\b' } |
                    ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
                throw "Compilation failed on package '$($pkg.name)' for platform '$platform'."
            }
        }

        # Update Delphi library paths in registry
        Update-LibraryPaths -BdsVersion    $DelphiVersion.BdsVersion `
                            -Platform      $platform `
                            -ProjectDir    $ProjectDir `
                            -PlatformConfig $platformConfig
    }

    Write-Host ""
    Write-Host "All packages compiled successfully." -ForegroundColor Green
}

function Get-GitHubRepoInfo {
    param([string]$RepoUrl)

    $uri   = [Uri]$RepoUrl
    $parts = $uri.AbsolutePath.Trim('/').Split('/')
    if ($parts.Count -lt 2) {
        throw "Invalid GitHub URL: $RepoUrl"
    }
    $owner = $parts[0]
    $repo  = $parts[1]

    $headers = @{ 'User-Agent' = 'BLOCKS/1.0' }

    try {
        $repoInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo" `
                                      -Headers $headers -ErrorAction Stop
    }
    catch {
        throw "Failed to retrieve repository information: $_"
    }

    $defaultBranch = $repoInfo.default_branch

    try {
        $commitInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/commits/$defaultBranch" `
                                        -Headers $headers -ErrorAction Stop
        $latestSha = $commitInfo.sha
    }
    catch {
        throw "Failed to retrieve latest commit: $_"
    }

    return [PSCustomObject]@{
        Owner         = $owner
        Repo          = $repo
        DefaultBranch = $defaultBranch
        LatestCommit  = $latestSha
    }
}

function Get-GitHubZipUrl {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$CommitSha
    )
    return "https://api.github.com/repos/$Owner/$Repo/zipball/$CommitSha"
}

function Download-AndExtract {
    param(
        [string]$ZipUrl,
        [string]$DestinationDir,
        [string]$ProjectName = '',
        [switch]$Overwrite,
        [switch]$Silent
    )

    $blocksDir   = Join-Path $DestinationDir '.blocks'
    $downloadDir = Join-Path $blocksDir 'download'
    $zipPath     = Join-Path $downloadDir 'download.zip'

    # Prepare temp download directory
    if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    Write-Host "Downloading..." -ForegroundColor Cyan
    try {
        $headers = @{ 'User-Agent' = 'BLOCKS/1.0' }
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -Headers $headers
    }
    catch {
        throw "Download failed: $_"
    }

    Write-Host "Extracting..." -ForegroundColor Cyan
    $extractDir = Join-Path $downloadDir 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # GitHub wraps content in a subdirectory (e.g. "owner-repo-abc1234")
    $innerDir = Get-ChildItem $extractDir -Directory | Select-Object -First 1
    if ($null -eq $innerDir) {
        throw "Unexpected zip structure: no subdirectory found."
    }

    $finalPath = Join-Path $DestinationDir $ProjectName

    if (Test-Path $finalPath) {
        if ($Overwrite) {
            Remove-Item $finalPath -Recurse -Force
            Write-Host "Directory '$finalPath' removed." -ForegroundColor Yellow
        }
        elseif ($Silent) {
            throw "Directory '$finalPath' already exists. Use -Overwrite to replace it."
        }
        else {
            Write-Host "Directory '$finalPath' already exists." -ForegroundColor Yellow
            $confirm = Read-Host "Overwrite? [Y/N] (default: N)"
            if ($confirm -notin @('Y', 'y')) {
                throw "Operation cancelled by user."
            }
            Remove-Item $finalPath -Recurse -Force
            Write-Host "Directory removed." -ForegroundColor Yellow
        }
    }

    # Move extracted folder to final destination
    Move-Item -Path $innerDir.FullName -Destination $finalPath

    # Cleanup .blocks\download
    Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue

    return $finalPath
}

# ==============================================================================
# DATABASE
# ==============================================================================

function Get-NormalizedLibraryId {
    param([string]$Id)
    # Normalize owner/repo separator to '.' (blocks-style)
    # e.g. "paolo-rossi/delphi-neon" and "paolo-rossi.delphi-neon" → "paolo-rossi.delphi-neon"
    $bare  = $Id -replace '@.*$', ''
    $parts = $bare -split '[./]', 2
    if ($parts.Count -eq 2) { return "$($parts[0]).$($parts[1])" }
    return $bare
}

function Remove-BlocksEntry {
    param(
        [string]$WorkDir,
        [string]$LibraryId,
        [string]$DelphiVersionName
    )

    $dbPath = Join-Path $WorkDir ".blocks\$DelphiVersionName-database.json"

    if (-not (Test-Path $dbPath)) {
        Write-Host "Database not found: $dbPath" -ForegroundColor Yellow
        return
    }

    $db           = (Get-Content -Path $dbPath -Raw) | ConvertFrom-Json
    $normalizedId = Get-NormalizedLibraryId -Id $LibraryId
    $before       = $db.blocks.Count
    $db.blocks    = @($db.blocks | Where-Object { (Get-NormalizedLibraryId -Id ($_  -replace '@.*$', '')) -ne $normalizedId })

    if ($db.blocks.Count -lt $before) {
        $db | ConvertTo-Json -Depth 5 | Set-Content -Path $dbPath -Encoding UTF8
        Write-Host "Removed from database: $normalizedId" -ForegroundColor DarkGray
    }
    else {
        Write-Host "Entry not found in database: $normalizedId" -ForegroundColor Yellow
    }
}

function Update-BlocksDatabase {
    param(
        [string]$WorkDir,
        [string]$LibraryId,
        [string]$CommitSha,
        [string]$DelphiVersionName
    )

    $dbPath = Join-Path $WorkDir ".blocks\$DelphiVersionName-database.json"

    if (Test-Path $dbPath) {
        $db = (Get-Content -Path $dbPath -Raw) | ConvertFrom-Json
    }
    else {
        $db = [PSCustomObject]@{ blocks = @() }
    }

    $normalizedId = Get-NormalizedLibraryId -Id $LibraryId
    $entry        = "$normalizedId@$CommitSha"

    # Remove any existing entry for the same library (regardless of commit)
    $db.blocks = @($db.blocks | Where-Object { (Get-NormalizedLibraryId -Id ($_ -replace '@.*$', '')) -ne $normalizedId })

    # Add the new entry
    $db.blocks = @($db.blocks) + $entry

    $db | ConvertTo-Json -Depth 5 | Set-Content -Path $dbPath -Encoding UTF8
    Write-Host "Database updated: $entry" -ForegroundColor DarkGray
}

# ==============================================================================
# DEPENDENCY INSTALLER
# ==============================================================================

function Install-Dependency {
    param(
        [string]$DependencySpec,
        [object]$SelectedVersion,
        [string]$WorkDir,
        [switch]$Silent,
        [switch]$Overwrite,
        [int]$Depth = 0
    )

    $indent = '  ' * ($Depth + 1)

    # Parse "owner/repo@commitsha"
    if ($DependencySpec -match '^([^@]+)@(.+)$') {
        $depId     = $Matches[1].Trim()
        $reqCommit = $Matches[2].Trim()
    }
    else {
        $depId     = $DependencySpec.Trim()
        $reqCommit = ''
    }

    $normalizedId = Get-NormalizedLibraryId -Id $depId

    # Load dependency config (needed for the name)
    $depConfig = (Get-ConfigJson -Source $depId) | ConvertFrom-Json

    Write-Host "${indent}--- $normalizedId / $($depConfig.application.name) ---" -ForegroundColor White

    # Check if already installed in database
    $dbPath = Join-Path $WorkDir ".blocks\$($SelectedVersion.VersionName)-database.json"
    if (Test-Path $dbPath) {
        $db       = (Get-Content $dbPath -Raw) | ConvertFrom-Json
        $existing = $db.blocks | Where-Object {
            (Get-NormalizedLibraryId -Id ($_ -replace '@.*$', '')) -eq $normalizedId
        }
        if ($existing) {
            $installedCommit = ($existing -split '@', 2)[1]
            if ([string]::IsNullOrWhiteSpace($reqCommit) -or $installedCommit -eq $reqCommit) {
                Write-Host "${indent}[OK] Already installed" -ForegroundColor Green
                return
            }
            else {
                Write-Host "${indent}[WARN] Installed @ $installedCommit, required: $reqCommit" -ForegroundColor Yellow
                if ($Silent) {
                    Write-Host "${indent}Continuing with installed version (-Silent)." -ForegroundColor Yellow
                    return
                }
                Write-Host "${indent}  [S] Stop"
                Write-Host "${indent}  [K] Keep installed version and continue"
                Write-Host "${indent}  [I] Install required version"
                $choice = Read-Host "${indent}Choose"
                switch ($choice.ToUpper()) {
                    'K' { return }
                    'I' { break }
                    default { throw "Dependency commit mismatch: $normalizedId" }
                }
            }
        }
    }

    # Recurse into sub-dependencies first
    if ($depConfig.dependencies -and $depConfig.dependencies.Count -gt 0) {
        foreach ($subDep in $depConfig.dependencies) {
            Install-Dependency -DependencySpec $subDep -SelectedVersion $SelectedVersion `
                               -WorkDir $WorkDir -Silent:$Silent -Overwrite:$Overwrite -Depth ($Depth + 1)
        }
    }

    # Resolve package folder for this dependency
    $packageFolders = @{}
    $depConfig.'package options'.'package folders'.PSObject.Properties |
        ForEach-Object { $packageFolders[$_.Name] = $_.Value }
    $packageFolder = Get-PackageFolder -InstalledVersionName $SelectedVersion.VersionName `
                                       -InstalledBdsVersion $SelectedVersion.BdsVersion `
                                       -PackageFolders $packageFolders

    # Resolve commit (fetch latest if not pinned)
    $owner = $normalizedId.Split('.')[0]
    $repo  = $normalizedId.Split('.')[1]
    if ([string]::IsNullOrWhiteSpace($reqCommit)) {
        $repoInfo  = Get-GitHubRepoInfo -RepoUrl $depConfig.application.url
        $reqCommit = $repoInfo.LatestCommit
        Write-Host "${indent}Using latest commit: $reqCommit"
    }

    # Download and extract
    $zipUrl     = Get-GitHubZipUrl -Owner $owner -Repo $repo -CommitSha $reqCommit
    $projectDir = Download-AndExtract -ZipUrl $zipUrl -DestinationDir $WorkDir `
                                      -ProjectName $depConfig.application.name `
                                      -Overwrite:$Overwrite -Silent:$Silent

    # Build
    Invoke-PackageBuild -DelphiVersion $SelectedVersion `
                        -ProjectDir    $projectDir `
                        -PackageFolder $packageFolder `
                        -Packages      $depConfig.packages `
                        -SupportedPlatforms $depConfig.supportedPlatforms

    # Register in database
    Update-BlocksDatabase -WorkDir $WorkDir -LibraryId $depConfig.application.id `
                          -CommitSha $reqCommit -DelphiVersionName $SelectedVersion.VersionName

    Write-Host "${indent}[DONE] $normalizedId" -ForegroundColor Green
}

# ==============================================================================
# CONFIG LOADER
# ==============================================================================

function Get-ConfigJson {
    param([string]$Source)

    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw "-Install is required. Use -Help for usage information."
    }

    # If not a URL and not ending in .json, treat as an ID and resolve from .blocks\repository\
    # Supports both "owner.repo" (dot) and "owner/repo" (slash) notation
    if ($Source -notmatch '^https?://' -and $Source -notlike '*.json') {
        $parts   = $Source -split '[./]', 2
        $subPath = "$($parts[0])\$($parts[1]).json"
        $Source  = Join-Path (Get-Location).Path ".blocks\repository\$subPath"
        Write-Host "Resolving ID to: $Source" -ForegroundColor DarkGray
    }

    if ($Source -match '^https?://') {
        try {
            $headers = @{ 'User-Agent' = 'BLOCKS/1.0' }
            return (Invoke-WebRequest -Uri $Source -Headers $headers -ErrorAction Stop).Content
        }
        catch {
            throw "Failed to load remote config: $_"
        }
    }
    else {
        if (-not (Test-Path $Source)) {
            throw "Config file not found: $Source"
        }
        return Get-Content -Path $Source -Raw
    }
}

# ==============================================================================
# INIT
# ==============================================================================

function Initialize-Workspace {
    param([string]$WorkDir)

    $blocksDir     = Join-Path $WorkDir '.blocks'
    $repositoryDir = Join-Path $blocksDir 'repository'
    $downloadDir   = Join-Path $blocksDir 'download'
    $zipPath       = Join-Path $downloadDir 'repository.zip'

    # Create .blocks directory if needed
    if (-not (Test-Path $blocksDir)) {
        New-Item -ItemType Directory -Path $blocksDir -Force | Out-Null
        Write-Host "Created: $blocksDir" -ForegroundColor Green
    }

    # Prepare temp download directory
    if (Test-Path $downloadDir) { Remove-Item $downloadDir -Recurse -Force }
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    Write-Host "Fetching repository info..." -ForegroundColor Cyan
    $repoInfo = Get-GitHubRepoInfo -RepoUrl $BlocksRepositoryUrl
    Write-Host "  Branch : $($repoInfo.DefaultBranch)"
    Write-Host "  Latest : $($repoInfo.LatestCommit)"
    Write-Host ""

    $zipUrl = Get-GitHubZipUrl -Owner $repoInfo.Owner -Repo $repoInfo.Repo -CommitSha $repoInfo.LatestCommit

    Write-Host "Downloading repository..." -ForegroundColor Cyan
    try {
        $headers = @{ 'User-Agent' = 'BLOCKS/1.0' }
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -Headers $headers
    }
    catch {
        throw "Download failed: $_"
    }

    Write-Host "Extracting..." -ForegroundColor Cyan
    $extractDir = Join-Path $downloadDir 'extract'
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    # GitHub wraps content in a subdirectory (e.g. "lminuti-blocks-repository-abc1234")
    $innerDir = Get-ChildItem $extractDir -Directory | Select-Object -First 1
    if ($null -eq $innerDir) {
        throw "Unexpected zip structure: no subdirectory found."
    }

    # Find .blocks\repository inside the extracted folder
    $sourceRepo = Join-Path $innerDir.FullName '.blocks\repository'
    if (-not (Test-Path $sourceRepo)) {
        throw "Repository folder not found in downloaded archive: .blocks\repository"
    }

    # Overwrite local .blocks\repository
    if (Test-Path $repositoryDir) {
        Write-Host "Directory '$repositoryDir' already exists." -ForegroundColor Yellow
        $confirm = Read-Host "Overwrite? [Y/N] (default: N)"
        if ($confirm -notin @('Y', 'y')) {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        Remove-Item $repositoryDir -Recurse -Force
    }
    Copy-Item -Path $sourceRepo -Destination $repositoryDir -Recurse -Force
    Write-Host "Repository updated: $repositoryDir" -ForegroundColor Green

    # Cleanup
    Remove-Item $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ==============================================================================
# HELP
# ==============================================================================

function Show-Help {
    Write-Host ""
    Write-Host "Usage: $script:ScriptName [options]" -ForegroundColor White
    Write-Host ""
    Write-Host "Options:" -ForegroundColor White
    Write-Host "  -Silent              Skip all non-critical prompts (uses defaults)."
    Write-Host "                       Critical prompts (Delphi version, overwrite) are still shown."
    Write-Host "  -Overwrite           Automatically overwrite existing project directory without asking."
    Write-Host "  -Product <version>   Select Delphi version by its internal name (no quoting needed)."
    Write-Host "                       Use -ListProducts to see available values."
    Write-Host "  -Install <path|url>  Load configuration from a local file or remote URL (http/https)"
    Write-Host "                          instead of the embedded configuration."
    Write-Host "  -Commit <sha>        Download a specific commit SHA instead of the latest."
    Write-Host "  -WorkspacePath <dir> Working directory (default: current directory)."
    Write-Host "  -ProjectFolder <dir> Override the project directory name (default: application name from config)."
    Write-Host "  -Uninstall           Remove the project directory and its database entry."
    Write-Host "  -BuildOnly           Skip download. Assumes project is already in place, runs build only."
    Write-Host "                       Without -ProjectFolder, falls back to the application name in config."
    Write-Host "  -Init                Initialize the workspace: create .blocks\ and download the package repository."
    Write-Host "                       Use with -WorkspacePath to target a different directory."
    Write-Host "  -ListProducts        Show installed Delphi versions and exit."
    Write-Host "  -List                Show packages installed in the current workspace (all Delphi versions)."
    Write-Host "                       Use with -Product to filter by Delphi version."
    Write-Host "                       Use with -WorkspacePath to target a different workspace."
    Write-Host "  -Help                Show this help message."
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor White
    Write-Host "  $script:ScriptName"
    Write-Host "  $script:ScriptName -Silent -Overwrite"
    Write-Host "  $script:ScriptName -Product delphi12 -Overwrite"
    Write-Host "  $script:ScriptName -BuildOnly -Silent -Product delphi13"
    Write-Host "  $script:ScriptName -Install C:\repository\mylib.json"
    Write-Host "  $script:ScriptName -Install https://example.com/repository/mylib.json"
    Write-Host ""
}

function Show-InstalledPackages {
    param([array]$InstalledVersions, [string]$WorkDir)

    # Determine which Delphi versions to list
    if (-not [string]::IsNullOrWhiteSpace($script:Product)) {
        $targets = $InstalledVersions | Where-Object {
            $_.DisplayName -ieq $script:Product -or $_.VersionName -ieq $script:Product
        }
        if ($targets.Count -eq 0) {
            throw "Product '$($script:Product)' not found among installed Delphi versions."
        }
    }
    else {
        $targets = $InstalledVersions
    }

    $found = $false
    foreach ($v in $targets) {
        $dbPath = Join-Path $WorkDir ".blocks\$($v.VersionName)-database.json"
        if (-not (Test-Path $dbPath)) { continue }

        $db = (Get-Content -Path $dbPath -Raw) | ConvertFrom-Json
        if (-not $db.blocks -or $db.blocks.Count -eq 0) { continue }

        $found = $true
        Write-Host ""
        Write-Host "  $($v.DisplayName)" -ForegroundColor Cyan
        Write-Host ""
        foreach ($entry in $db.blocks) {
            if ($entry -match '^([^@]+)@(.+)$') {
                $id     = $Matches[1]
                $commit = $Matches[2]
                Write-Host ("    {0,-35} {1}" -f $id, $commit.Substring(0, [Math]::Min(7, $commit.Length)))
            }
            else {
                Write-Host "    $entry"
            }
        }
    }

    if (-not $found) {
        Write-Host ""
        Write-Host "  No packages installed." -ForegroundColor Yellow
    }
    Write-Host ""
}

function Show-InstalledVersions {
    $installedVersions = Get-InstalledDelphiVersions
    if ($installedVersions.Count -eq 0) {
        Write-Host "No Delphi versions found in the registry." -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "Installed Delphi versions:" -ForegroundColor White
    Write-Host ""
    foreach ($v in $installedVersions) {
        Write-Host ("  {0,-20} {1}" -f $v.VersionName, $v.DisplayName)
    }
    Write-Host ""
}

# ==============================================================================
# MAIN
# ==============================================================================

try {
    $noArgs = (-not $Help) -and (-not $ListProducts) -and (-not $List) -and (-not $Init) -and (-not $Uninstall) -and [string]::IsNullOrWhiteSpace($Install)
    if ($noArgs) {
        Show-Banner -AppName '' -Description ''
        Show-Help
        exit 0
    }

    if ($Help) {
        Show-Banner -AppName '' -Description ''
        Show-Help
        exit 0
    }

    if ($ListProducts) {
        Show-Banner -AppName '' -Description ''
        Show-InstalledVersions
        exit 0
    }

    if ($List) {
        Show-Banner -AppName '' -Description ''
        $installedVersions = Get-InstalledDelphiVersions
        $workDir = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath } else { (Get-Location).Path }
        Write-Host "Installed packages in: $workDir" -ForegroundColor White
        Show-InstalledPackages -InstalledVersions $installedVersions -WorkDir $workDir
        exit 0
    }

    if ($Init) {
        Show-Banner -AppName '' -Description ''
        $workDir = if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) { $WorkspacePath } else { (Get-Location).Path }
        Write-Host "Initializing workspace: $workDir" -ForegroundColor White
        Write-Host ""
        Initialize-Workspace -WorkDir $workDir
        Write-Host ""
        Write-Host "Workspace initialized." -ForegroundColor Green
        Write-Host ""
        exit 0
    }

    if ($Uninstall -and [string]::IsNullOrWhiteSpace($Install)) {
        throw "-Uninstall requires a package ID, path, or URL. Usage: blocks -Uninstall <id>"
    }

    # Step 1 — Working directory
    if (-not [string]::IsNullOrWhiteSpace($WorkspacePath)) {
        if (-not (Test-Path $WorkspacePath -PathType Container)) {
            New-Item -ItemType Directory -Path $WorkspacePath -Force | Out-Null
        }
        $workDir = $WorkspacePath
    }
    else {
        $workDir = (Get-Location).Path
    }

    # Check if .blocks exists; offer to initialize if not
    $blocksDir = Join-Path $workDir '.blocks'
    if (-not (Test-Path $blocksDir)) {
        Write-Host ""
        Write-Host "The current directory is not a valid Blocks workspace." -ForegroundColor Yellow
        Write-Host "Proceeding will initialize it by downloading the package repository." -ForegroundColor Yellow
        Write-Host ""
        $confirm = Read-Host "Initialize workspace now? [Y/N] (default: N)"
        if ($confirm -notin @('Y', 'y')) {
            throw "Operation cancelled. Run 'blocks -Init' to initialize the workspace first."
        }
        Initialize-Workspace -WorkDir $workDir
        Write-Host ""
    }

    # Parse optional @commit suffix from -Install (e.g. "owner.pkg@abc1234")
    $installSource = $Install
    $installCommit = ''
    if ($Install -match '^([^@]+)@(.+)$') {
        $installSource = $Matches[1].Trim()
        $installCommit = $Matches[2].Trim()
    }

    $config = (Get-ConfigJson -Source $installSource) | ConvertFrom-Json

    Show-Banner -AppName $config.application.name -Description $config.application.description

    if (-not [string]::IsNullOrWhiteSpace($Install)) {
        Write-Host "Config: $Install" -ForegroundColor DarkGray
        Write-Host ""
    }

    Test-DelphiRunning

    Write-Host "Workspace: $workDir" -ForegroundColor DarkGray
    Write-Host ""

    # Step 2 — Delphi version
    $installedVersions = Get-InstalledDelphiVersions
    $selectedVersion   = Select-DelphiVersion -InstalledVersions $installedVersions
    Write-Host "Selected version: $($selectedVersion.DisplayName)`n" -ForegroundColor Green

    if ($Uninstall) {
        $dirName    = if (-not [string]::IsNullOrWhiteSpace($ProjectFolder)) { $ProjectFolder } else { $config.application.name }
        $projectDir = Join-Path $workDir $dirName

        if (Test-Path $projectDir) {
            Remove-Item $projectDir -Recurse -Force
            Write-Host "Removed: $projectDir" -ForegroundColor Yellow
        }
        else {
            Write-Host "Directory not found: $projectDir" -ForegroundColor Yellow
        }

        # TODO: remove Search Path, Browsing Path and Debug DCU Path entries
        #       from the Delphi registry for all supported platforms

        Remove-BlocksEntry -WorkDir $workDir -LibraryId $config.application.id -DelphiVersionName $selectedVersion.VersionName

        Write-Host ""
        Write-Host "Uninstalled: $($config.application.name)" -ForegroundColor Green
        Write-Host ""
        exit 0
    }

    # Resolve package folder for selected Delphi version
    $packageFolders = @{}
    $config.'package options'.'package folders'.PSObject.Properties |
        ForEach-Object { $packageFolders[$_.Name] = $_.Value }

    $packageFolder = Get-PackageFolder -InstalledVersionName $selectedVersion.VersionName `
                                       -InstalledBdsVersion $selectedVersion.BdsVersion `
                                       -PackageFolders $packageFolders

    # Step 3 — Dependencies
    if ($config.dependencies -and $config.dependencies.Count -gt 0) {
        Write-Host "Resolving dependencies..." -ForegroundColor Cyan
        foreach ($dep in $config.dependencies) {
            Install-Dependency -DependencySpec $dep -SelectedVersion $selectedVersion `
                               -WorkDir $workDir -Silent:$Silent -Overwrite:$Overwrite
        }
        Write-Host ""
    }

    if (-not $BuildOnly) {
        # Step 4 — Resolve commit and download
        Write-Host "--- $(Get-NormalizedLibraryId -Id $config.application.id) / $($config.application.name) ---" -ForegroundColor White
        Write-Host "Fetching repository info..." -ForegroundColor Cyan
        $repoInfo = Get-GitHubRepoInfo -RepoUrl $config.application.url
        Write-Host "  Branch : $($repoInfo.DefaultBranch)"
        Write-Host "  Latest : $($repoInfo.LatestCommit)"
        Write-Host ""

        if (-not [string]::IsNullOrWhiteSpace($installCommit)) {
            $commitSha = $installCommit
            Write-Host "Commit: $commitSha (from @)"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Commit)) {
            $commitSha = $Commit.Trim()
            Write-Host "Commit: $commitSha (from -Commit)"
        }
        else {
            $commitSha = $repoInfo.LatestCommit
            Write-Host "Commit: $commitSha (latest)"
        }
        Write-Host ""

        $zipUrl     = Get-GitHubZipUrl -Owner $repoInfo.Owner -Repo $repoInfo.Repo -CommitSha $commitSha
        $dirName    = if (-not [string]::IsNullOrWhiteSpace($ProjectFolder)) { $ProjectFolder } else { $config.application.name }
        $projectDir = Download-AndExtract -ZipUrl $zipUrl -DestinationDir $workDir `
                                          -ProjectName $dirName `
                                          -Overwrite:$Overwrite -Silent:$Silent

        Write-Host "Project downloaded to: $projectDir" -ForegroundColor Green
        Write-Host ""
    }
    else {
        # Build-only: use -ProjectFolder if given, otherwise fall back to application name
        $dirName = if (-not [string]::IsNullOrWhiteSpace($ProjectFolder)) { $ProjectFolder } else { $config.application.name }
        $projectDir = Join-Path $workDir $dirName
        if (-not (Test-Path $projectDir)) {
            throw "Build-only mode: project directory not found: $projectDir"
        }
        Write-Host "Build-only mode. Using existing directory: $projectDir" -ForegroundColor Yellow
        Write-Host ""
    }

    # Step 5 — Compile packages
    Invoke-PackageBuild -DelphiVersion $selectedVersion `
                        -ProjectDir    $projectDir `
                        -PackageFolder $packageFolder `
                        -Packages           $config.packages `
                        -SupportedPlatforms $config.supportedPlatforms

    if (-not $BuildOnly) {
        Update-BlocksDatabase -WorkDir $workDir -LibraryId $config.application.id -CommitSha $commitSha -DelphiVersionName $selectedVersion.VersionName
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  Done!"                                      -ForegroundColor Green
    Write-Host "  Project : $projectDir"                     -ForegroundColor Green
    Write-Host "  Packages: $(Join-Path $projectDir "packages\$packageFolder")" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "ERROR: $_" -ForegroundColor Red
    Write-Host ""
    exit 1
}
