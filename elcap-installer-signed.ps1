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

# SIG # Begin signature block
# MIIoZQYJKoZIhvcNAQcCoIIoVjCCKFICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDhaSFsndIoe8Gv
# RcDspkg1VqqEeY0sed4jaIO9WngytqCCDZswggawMIIEmKADAgECAhAIrUCyYNKc
# TJ9ezam9k67ZMA0GCSqGSIb3DQEBDAUAMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNV
# BAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAeFw0yMTA0MjkwMDAwMDBaFw0z
# NjA0MjgyMzU5NTlaMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQDVtC9C0CiteLdd1TlZG7GIQvUzjOs9gZdwxbvEhSYwn6SOaNhc9es0
# JAfhS0/TeEP0F9ce2vnS1WcaUk8OoVf8iJnBkcyBAz5NcCRks43iCH00fUyAVxJr
# Q5qZ8sU7H/Lvy0daE6ZMswEgJfMQ04uy+wjwiuCdCcBlp/qYgEk1hz1RGeiQIXhF
# LqGfLOEYwhrMxe6TSXBCMo/7xuoc82VokaJNTIIRSFJo3hC9FFdd6BgTZcV/sk+F
# LEikVoQ11vkunKoAFdE3/hoGlMJ8yOobMubKwvSnowMOdKWvObarYBLj6Na59zHh
# 3K3kGKDYwSNHR7OhD26jq22YBoMbt2pnLdK9RBqSEIGPsDsJ18ebMlrC/2pgVItJ
# wZPt4bRc4G/rJvmM1bL5OBDm6s6R9b7T+2+TYTRcvJNFKIM2KmYoX7BzzosmJQay
# g9Rc9hUZTO1i4F4z8ujo7AqnsAMrkbI2eb73rQgedaZlzLvjSFDzd5Ea/ttQokbI
# YViY9XwCFjyDKK05huzUtw1T0PhH5nUwjewwk3YUpltLXXRhTT8SkXbev1jLchAp
# QfDVxW0mdmgRQRNYmtwmKwH0iU1Z23jPgUo+QEdfyYFQc4UQIyFZYIpkVMHMIRro
# OBl8ZhzNeDhFMJlP/2NPTLuqDQhTQXxYPUez+rbsjDIJAsxsPAxWEQIDAQABo4IB
# WTCCAVUwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUaDfg67Y7+F8Rhvv+
# YXsIiGX0TkIwHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6mK4cD08wDgYDVR0P
# AQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMDMHcGCCsGAQUFBwEBBGswaTAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEEGCCsGAQUFBzAC
# hjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9v
# dEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3JsMy5kaWdpY2VydC5j
# b20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAcBgNVHSAEFTATMAcGBWeBDAED
# MAgGBmeBDAEEATANBgkqhkiG9w0BAQwFAAOCAgEAOiNEPY0Idu6PvDqZ01bgAhql
# +Eg08yy25nRm95RysQDKr2wwJxMSnpBEn0v9nqN8JtU3vDpdSG2V1T9J9Ce7FoFF
# UP2cvbaF4HZ+N3HLIvdaqpDP9ZNq4+sg0dVQeYiaiorBtr2hSBh+3NiAGhEZGM1h
# mYFW9snjdufE5BtfQ/g+lP92OT2e1JnPSt0o618moZVYSNUa/tcnP/2Q0XaG3Ryw
# YFzzDaju4ImhvTnhOE7abrs2nfvlIVNaw8rpavGiPttDuDPITzgUkpn13c5Ubdld
# AhQfQDN8A+KVssIhdXNSy0bYxDQcoqVLjc1vdjcshT8azibpGL6QB7BDf5WIIIJw
# 8MzK7/0pNVwfiThV9zeKiwmhywvpMRr/LhlcOXHhvpynCgbWJme3kuZOX956rEnP
# LqR0kq3bPKSchh/jwVYbKyP/j7XqiHtwa+aguv06P0WmxOgWkVKLQcBIhEuWTatE
# QOON8BUozu3xGFYHKi8QxAwIZDwzj64ojDzLj4gLDb879M4ee47vtevLt/B3E+bn
# KD+sEq6lLyJsQfmCXBVmzGwOysWGw/YmMwwHS6DTBwJqakAwSEs0qFEgu60bhQji
# WQ1tygVQK+pKHJ6l/aCnHwZ05/LWUpD9r4VIIflXO7ScA+2GRfS0YW6/aOImYIbq
# yK+p/pQd52MbOoZWeE4wggbjMIIEy6ADAgECAhABRjuB/xwoa73ek7ES73ouMA0G
# CSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwg
# SW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNpZ25pbmcg
# UlNBNDA5NiBTSEEzODQgMjAyMSBDQTEwHhcNMjUwMjEzMDAwMDAwWhcNMjgwMjE0
# MjM1OTU5WjBrMQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTERMA8G
# A1UEBxMIQ2FybHNiYWQxGTAXBgNVBAoTEFRyaWRlbnQgaU90LCBMTEMxGTAXBgNV
# BAMTEFRyaWRlbnQgaU90LCBMTEMwggGiMA0GCSqGSIb3DQEBAQUAA4IBjwAwggGK
# AoIBgQDH3+Sq1mCCIuQxCYqzcfalkGsM8hFRgVUoev2Z65wikCgjgob9fQEmC4Ya
# K/ybQsXyk5mVzocY4D7DE0wPY9hpC4/EsGXoZHbLMQqVT/qaSykAUQjjhtn52BB0
# AoORPvnkLuTnNCQMpF+PfWrP9Es0yd8mfwcFzlsDhCwvB/D9q096U+K1UmU/5Zgk
# GOem4kXfl5D+fJVxmWMED28iXrVTxK3CWSX1PcKjtZ9z+kLbuEeJQPu2ayzLLphX
# t0d+hdFpinS8FO5DFoD91YDCOLkfc+ARkjAriwinwagJNCQbBaMJABp+7Mv0kmZB
# Ku0OvSjDCDxRRvtE2zyYqLOQscMDi5Rt2o/kR0+vdfKH+s2rcmoc2wLLswnseVH2
# 1j/yk4sZzpxDwz+jdyamZ8esGvrh5AXhF/YURI8qWWnQLV3ifjihTz7G+uAPbRQJ
# KgQq/+yI/XOmOJhyxWaCaSs5DOrEKGbZEcNtUMADiPTUQyp1U0O7tE/7dgN3gU5U
# 5WxIdwUCAwEAAaOCAgMwggH/MB8GA1UdIwQYMBaAFGg34Ou2O/hfEYb7/mF7CIhl
# 9E5CMB0GA1UdDgQWBBTIVlfO3mRGDvRFv4yUNlSoDYra+zA+BgNVHSAENzA1MDMG
# BmeBDAEEATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9D
# UFMwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMDMIG1BgNVHR8E
# ga0wgaowU6BRoE+GTWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRy
# dXN0ZWRHNENvZGVTaWduaW5nUlNBNDA5NlNIQTM4NDIwMjFDQTEuY3JsMFOgUaBP
# hk1odHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRDb2Rl
# U2lnbmluZ1JTQTQwOTZTSEEzODQyMDIxQ0ExLmNybDCBlAYIKwYBBQUHAQEEgYcw
# gYQwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBcBggrBgEF
# BQcwAoZQaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZEc0Q29kZVNpZ25pbmdSU0E0MDk2U0hBMzg0MjAyMUNBMS5jcnQwCQYDVR0TBAIw
# ADANBgkqhkiG9w0BAQsFAAOCAgEAikBh0BtrzX4MwUzxbWVXVXfzmmmpJHDrlb8+
# bkt8nTi8cLOo8B7xweuy711pCY9fV6+hcv17VYvh52sDKjt5gPfwDR8QJ752bcLy
# 47M4VkK8poWVUR12XK7zqzetenIY9/i8rZYeE80w37rP9rp+/A5JnkMwnBJsXs8E
# YZUlNKyh1JCf50ebslXIoN8bjiiGTFKBc4rEHBVFizLFZO85kmy5PDc+wB0brqoS
# T/d1bxJSdegbwAwvutR+nGCaLeXK2iQu8XOUTjcwLzUtiDRTSWJJLEcIs9CB8+7W
# qXe4UGwRRnEtBqYXiSNOnwL6ynrUp0x3kfK5gxRU4r4DDx/QlLFEKzCQBN4hPTn3
# W+1ATDfo1iE2Xe4FeJnYaRIEutXQP3/Nvs1VMiP3+9KTdWbq7sdRsTNxX31ECuzN
# ZziMYDIx65gQdtfUnW3cezJTsw0dCsKSmP9u/clqHpj+a5ArDdKoz4ZT4JbL2aNQ
# IlcX+MIr1l7+EnLx1RlSDFB+NozRLnzMk4+TEJ60FRB4du/FdTayilNyunpN2NT3
# KRG49IX6SqS7GsWc+U92kuxmrI36qx8UnTqUcZWFVBCNt6LbPtmcIIiuVedBycEf
# Xrdcm/NZYD12ZtG22aZvj1y04qZPofwlRkBjwO3eA7XgTxJ3RaajEagoXV2rLqdt
# etDH08YxghogMIIaHAIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdp
# Q2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBDb2RlIFNp
# Z25pbmcgUlNBNDA5NiBTSEEzODQgMjAyMSBDQTECEAFGO4H/HChrvd6TsRLvei4w
# DQYJYIZIAWUDBAIBBQCgfDAQBgorBgEEAYI3AgEMMQIwADAZBgkqhkiG9w0BCQMx
# DAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkq
# hkiG9w0BCQQxIgQgc+vQKKbRkbpxWBsvZJ1zHoCE7y3Rayv2+JRP22HHMIUwDQYJ
# KoZIhvcNAQEBBQAEggGAY2FnGx1djVwzEAtLa494KizXHADHacQAxL1ohbIIKdVY
# Ci6MB1ADNGwCJXnq9IFYHkFY9maTvqcuiiU3db1kuLvZDisFTQeLbn0VZdRMhWoF
# gF5lTzs6cwskxR8MQRa8Kzj7dPegRMSvhEgnLG79sYxQmQgFSY+/kDVIFUxWPB+9
# opkuYK98aEvCO5PhYj90Z1+DilnH6DXvZzAQ0r+HOy5suV6ejKnLKwkt8P6pYTXR
# FSF3YrsGK5zUTq+C2aLUlz/CDzGF4UW9M9jQA+aFy9oiR0yiaALX+X9YqFdixlou
# Wa4kIqdTljIncQui524uOlohgTbTZmeNV3MnH0pOjHNGfFFZv7cPjTf1VnWzxRTd
# NDvoKaZoiZEcVAnRw/Cogf0ysdACf8qIh1k5/9aQqV/K79mq3lNIpY6WN9tAQ+aq
# oZ2a/ocaY2fAzMekZZa23R5dyNcoC2crHvXiaApqH3aJleI8yV8o8CDbU1LwJ4SS
# Uqt2AcOybAEUk8P4HaKpoYIXdjCCF3IGCisGAQQBgjcDAwExghdiMIIXXgYJKoZI
# hvcNAQcCoIIXTzCCF0sCAQMxDzANBglghkgBZQMEAgEFADB3BgsqhkiG9w0BCRAB
# BKBoBGYwZAIBAQYJYIZIAYb9bAcBMDEwDQYJYIZIAWUDBAIBBQAEIHiPetfWAYPs
# SRP6TQxRmu227t6cW8u3kdmkWuNTacJzAhAcHWvAEZ9cqG5JoJs1udjhGA8yMDI2
# MDUwNjE5MDUxNVqgghM6MIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDAN
# BgkqhkiG9w0BAQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQs
# IEluYy4xQTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5n
# IFJTQTQwOTYgU0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkw
# MzIzNTk1OVowYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMu
# MTswOQYDVQQDEzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVz
# cG9uZGVyIDIwMjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBG
# rC0Sxp7Q6q5gVrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwB
# SOeLpvPnZ8ZN+vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/
# 4QhguSssp3qome7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3
# K3E0zz09ldQ//nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROU
# INDT98oksouTMYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3
# w6ySSSu+3qU8DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46Yce
# NA0LfNsnqcnpJeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d
# 2sC26/PQPdP51ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8x
# ymLnjCbSLZ49kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+
# AliL7ojTdS5PWPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2b
# Qhpp0IoKRR7YufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNV
# HRMBAf8EAjAAMB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSME
# GDAWgBTvb1NK6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0l
# AQH/BAwwCgYIKwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzAB
# hhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9j
# YWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGlu
# Z1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRw
# Oi8vY3JsMy5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBp
# bmdSU0E0MDk2U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIw
# CwYJYIZIAYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESe
# Y0ByIfjk9iJP2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FU
# FqNh+tshgb4O6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7Y
# MTmqPO9mzskgiC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0zi
# TN6R3ygQBHMUBaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/
# QqvXnNb+YkDFkxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlq
# AcuEVT0cKsb+zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3
# Y50OHgaY7T/lwd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roan
# cJIFcbojBcxlRcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/
# ndUlQ05oxYy2zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7
# IRE2lskKPIJgbaP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdC
# vHlshtjdNXOCIUjsarfNZzCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYw
# DQYJKoZIhvcNAQELBQAwYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0
# IEluYzEZMBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNl
# cnQgVHJ1c3RlZCBSb290IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1
# OVowaTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYD
# VQQDEzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNI
# QTI1NiAyMDI1IENBMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4
# MdMKmEFyvjxGwBysddujRmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6
# c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3
# SYDEAd4dg2dDGpeZGKe+42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVST
# EG8yAR2CQWIM1iI5PHg62IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpq
# umzTCNSOxm+SAWSuIr21Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJ
# yUXzdtFUUt4aS4CEeIY8y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/Gcal
# NeJQ55IuwnKCgs+nrpuQNfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8A
# w4wJkhU1JrPsFfxW1gaou30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/n
# J0+k6MvqzfpzPDOy5y6gqztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA
# 6tQbZl1KhBtTasySkuJDpsZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2ba
# oD6x0VR4RjSpWM8o5a6D8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNV
# HRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAf
# BgNVHSMEGDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYw
# EwYDVR0lBAwwCgYIKwYBBQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzAB
# hhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9j
# YWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMG
# A1UdHwQ8MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRSb290RzQuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG
# /WwHATANBgkqhkiG9w0BAQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCH
# xYgaMH9Pw5tcBnPw6O6FTGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdh
# OP4hCFATuNT+ReOPK0mCefSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDC
# vwzJv2sRUoKEfJ+nN57mQfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B
# 0ba2H3LUiwDRAXx1Neq9ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWG
# NqNX+DF0SQzHU0pTi4dBwp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRN
# ivYuve3L2oiKNqetRHdqfMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02Oo
# XN4bFzK0vlNMsvhlqgF2puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy
# 4kbu4QFhOm0xJuF2EZAOk5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2w
# L40mm53+/j7tFaxYKIqL0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQt
# yRN62JK4S1C8uw3PdBunvAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2
# zNaQ9k+5t1wwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqGSIb3
# DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAX
# BgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3Vy
# ZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTlaMGIx
# CzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3
# dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBH
# NDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8MCIw
# aTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauyefLK
# EdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34LzB4Tm
# dDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+xembu
# d8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhAkHnD
# eMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1LyuGwN1
# XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2PVld
# QnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37AlLTS
# YW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD76GSm
# M9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/ybzT
# QRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXAj6Kx
# fgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTADAQH/
# MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF66Kv
# 9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEEbTBr
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUH
# MAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNl
# cnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAIMAYG
# BFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979XB72a
# rKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4kvFID
# yE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU53/o
# Wajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pcVIxv
# 76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5vIy30
# fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQxggN8MIID
# eAIBATB9MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFB
# MD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5
# NiBTSEEyNTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIB
# BQCggdEwGgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEP
# Fw0yNjA1MDYxOTA1MTVaMCsGCyqGSIb3DQEJEAIMMRwwGjAYMBYEFN1iMKyGCi0w
# a9o4sWh5UjAH+0F+MC8GCSqGSIb3DQEJBDEiBCBIqXauk1WDkx2QqzUQ/7tyJg+U
# uTZeqwjHWWq5fg3qpzA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCBKoD+iLNdchMVc
# k4+CjmdrnK7Ksz/jbSaaozTxRhEKMzANBgkqhkiG9w0BAQEFAASCAgAx6rhfrev9
# prt/f4/U6S15jorfDulbVfpCiu+wR3nN21oOjMqj9nj8yWhhVhhQL0Smy2RhOJ0w
# U8byq4NeTTjWH6NBVVaLCv7nrL2yfdZVs4FHMXPxsLsc0X477u7XPIyO2mA/gQ5O
# 39gGuhIGCUXjERaN5USMj+rDfYdIN7cmYmFrx+4egRG2LfDuPG+Fh4GNCkBvfwaz
# NzLWAAyDBtuTtz93gsI3xrlOFJENXxfAk5wHOBmv2odoKDx9B+BN5gXcm/6RubaK
# VeoPkfcRJ+LL74zICfFnTjoqZ1LJUnK4TMqbz1Fi98osMNuBrUSY+R2jDINpwhG/
# Qq/4s4xkpmU82ReVz2w8Wvc97ziuyRysLQwGoQXHTlpSr2Gvv+2yVZsxbusK10MI
# TaiZFaVeSc5z9MYWe2DkO3cmbBMxq/oiUr7DayKUJO+w4p4eh1F5/fHTCmU2BgnY
# c7o5mG8saNhER4qAkFucL4BZP+9Ft+3VFBstVwy120F3Q9cwojQn0INvEMMo7VeV
# omvfhrE9P/8Swg28pBLKy8hi+x1ypzBoVPHZfEFi/k2jYKIeSFjh+541avjgXk3s
# PcgHcn0nPKNMkO0SKvW3KOfq4FdH+vteo6QwbcMpcY3YQJrDBfN6tdOnsxjXeg7G
# dr4i5XbI17927LPV539uVBKPT+AF0jyQYw==
# SIG # End signature block
