# ElCap Installer for Windows
# Usage:
#   powershell -ExecutionPolicy Bypass -c "irm https://github.com/tridentiot/elcap/releases/latest/download/elcap-installer.ps1 | iex"

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
$REPO   = 'tridentiot/elcap'
$BINARY = 'elcap'

# ---------------------------------------------------------------------------
# Architecture check
# ---------------------------------------------------------------------------
function Assert-Architecture {
    if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        Write-Information "Error: Unsupported architecture '$env:PROCESSOR_ARCHITECTURE'. elcap only supports x86_64 Windows."
        throw "Unsupported architecture '$env:PROCESSOR_ARCHITECTURE'"
    }
}

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------
function Resolve-Version {
    Write-Information "Fetching latest release version..."
    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$REPO/releases/latest" `
            -UseBasicParsing
        $resolvedVersion = $response.tag_name
    }
    catch {
        Write-Information "Error: could not determine latest version."
        throw
    }
    if (-not $resolvedVersion) {
        Write-Information "Error: could not determine latest version."
        throw
    }
    return $resolvedVersion
}

# ---------------------------------------------------------------------------
# Resolve install location
# ---------------------------------------------------------------------------
function Resolve-InstallDir {
    return Join-Path $HOME ".local\bin"
}

# ---------------------------------------------------------------------------
# Verify checksum
# ---------------------------------------------------------------------------
function Assert-Checksum {
    param(
        [string]$ZipPath,
        [string]$Artifact,
        [string]$Version
    )
    Write-Information "Verifying checksum..."
    $shasumsUrl = "https://github.com/$REPO/releases/download/$Version/SHASUMS256.txt"
    try {
        $shasums = Invoke-RestMethod -Uri $shasumsUrl -UseBasicParsing
    }
    catch {
        Write-Information "Error: failed to download SHASUMS256.txt"
        throw
    }

    $expectedHash = ($shasums -split "`n" | Where-Object { $_ -like "*$Artifact*" }) -split '\s+' | Select-Object -First 1
    if (-not $expectedHash) {
        Write-Information "Error: could not find checksum for $Artifact in SHASUMS256.txt"
        throw
    }

    $actualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash.ToUpper()) {
        Write-Information "Error: checksum mismatch for $Artifact. Download may be corrupted (expected $($expectedHash.ToUpper()), got $actualHash)"
        throw
    }
}

# ---------------------------------------------------------------------------
# Register with Add/Remove Programs
# ---------------------------------------------------------------------------
function Register-Uninstaller {
    param(
        [string]$Version,
        [string]$InstallDir
    )
    $uninstallKey = "registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\ElCap"
    New-Item -Path $uninstallKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $uninstallKey -Name "DisplayName"     -Value "ElCap"
    Set-ItemProperty -LiteralPath $uninstallKey -Name "DisplayVersion"  -Value $Version
    Set-ItemProperty -LiteralPath $uninstallKey -Name "Publisher"       -Value "TridentIoT"
    Set-ItemProperty -LiteralPath $uninstallKey -Name "InstallLocation" -Value $InstallDir
    Set-ItemProperty -LiteralPath $uninstallKey -Name "UninstallString" -Value "cmd /c del /f `"$InstallDir\elcap.exe`" & reg delete `"HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\ElCap`" /f"
}

# ---------------------------------------------------------------------------
# Download and install
# ---------------------------------------------------------------------------
function Main {
    Assert-Architecture

    $version    = Resolve-Version
    $artifact   = "$BINARY-$version-windows.zip"
    $url        = "https://github.com/$REPO/releases/download/$version/$artifact"
    $installDir = Resolve-InstallDir

    # Fail if elcap is already installed somewhere else on PATH
    $existing = Get-Command elcap -ErrorAction SilentlyContinue
    if ($existing) {
        $existingPath = $existing.Source
        if ($existingPath -notlike "*$installDir*") {
            Write-Information "Error: ElCap is already installed at: $existingPath"
            Write-Information "Please remove it before installing to avoid PATH conflicts."
            throw "ElCap already installed at unexpected location: $existingPath"
        }
    }

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    try {
        $zipPath = Join-Path $tmpDir $artifact

        Write-Information "Downloading $artifact..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        }
        catch {
            Write-Information "Error: failed to download $url"
            throw
        }

        Assert-Checksum -ZipPath $zipPath -Artifact $artifact -Version $version

        Write-Information "Installing to $installDir..."
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force

        $exePath = Join-Path $tmpDir "$BINARY.exe"
        if (-not (Test-Path $exePath)) {
            Write-Information "Error: could not find $BINARY.exe in the archive."
            throw
        }
        Copy-Item $exePath -Destination $installDir -Force

        # Add to PATH via registry
        $registryPath = 'registry::HKEY_CURRENT_USER\Environment'
        $currentPath = (Get-Item -LiteralPath $registryPath).GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        if ($currentPath -notlike "*$installDir*") {
            $newPath = "$installDir;$currentPath"
            Set-ItemProperty -Type ExpandString -LiteralPath $registryPath Path $newPath
            $dummyName = 'elcap-installer-' + [guid]::NewGuid().ToString()
            [Environment]::SetEnvironmentVariable($dummyName, 'dummy', 'User')
            [Environment]::SetEnvironmentVariable($dummyName, [NullString]::value, 'User')
            Write-Information "Added $installDir to PATH"
            Write-Information "Restart your shell or run: `$env:Path = `"$installDir;`$env:Path`""
        }

        # Register with Add/Remove Programs
        Register-Uninstaller -Version $version -InstallDir $installDir

        Write-Information "ElCap $version installed successfully!"
        Write-Information "Run 'elcap' to get started!"
        exit 0
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
try {
    Main
} catch {
    Write-Information ""
    Write-Information "Installation failed: $_"
    Write-Information "For alternative installation methods please refer to the documentation: https://tridentiot.github.io/elcap-cli/"
    exit 1
}
