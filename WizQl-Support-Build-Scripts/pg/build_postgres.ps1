# =============================================================================
# build_postgres.ps1
# Extracts, configures, and builds all PostgreSQL .tar.gz archives in a folder.
#
# Prerequisites: Visual Studio (with C++ workload), ActivePerl or Strawberry
# Perl, and optionally OpenSSL (Win64 from slproweb.com or choco install openssl)
# and ICU (choco install icu  or  download from github.com/unicode-org/icu/releases)
#
# Usage:
#   .\build_postgres.ps1 [-SourceDir <path>]
#   SourceDir   Folder containing postgresql-*.tar.gz  (default: current dir)
#
# Run from a "x64 Native Tools Command Prompt for VS" or the script will
# attempt to locate and invoke vcvarsall.bat automatically.
# =============================================================================

param(
    [string]$SourceDir = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers ------------------------------------------
function Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Success { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err     { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Header  { param($msg)
    Write-Host ""
    Write-Host "------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "------------------------------------------" -ForegroundColor Cyan
}

# -- Resolve source dir --------------------------------------
$SourceDir = Resolve-Path $SourceDir -ErrorAction Stop | Select-Object -ExpandProperty Path
$LogBase   = Join-Path $SourceDir "logs"
$Jobs      = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

Info "Source dir : $SourceDir"
Info "Build dir  : $SourceDir"
Info "Jobs       : $Jobs"

# -- Auto-initialize MSVC environment if not already set -----
if (-not $env:VCINSTALLDIR) {
    Info "MSVC environment not detected -- searching for vcvarsall.bat..."
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -property installationPath 2>$null
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
        if (Test-Path $vcvars) {
            Info "Found: $vcvars"
            # Import env vars exported by vcvarsall into current session
            $tempFile = [System.IO.Path]::GetTempFileName() + ".bat"
            "@echo off`r`ncall `"$vcvars`" x64`r`nset" | Set-Content $tempFile
            cmd /c $tempFile | ForEach-Object {
                if ($_ -match "^([^=]+)=(.*)$") {
                    [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], "Process")
                }
            }
            Remove-Item $tempFile -Force
            Success "MSVC x64 environment loaded."
        } else {
            Warn "vcvarsall.bat not found. Make sure Visual Studio C++ workload is installed."
        }
    } else {
        Warn "vswhere.exe not found. Install Visual Studio with the C++ workload."
    }
}

# -- Auto-detect Perl (required by pg <= 16 MSVC build) ------
$perl = Get-Command perl -ErrorAction SilentlyContinue
if (-not $perl) {
    Warn "Perl not found -- pg <= 16 builds will fail."
    Warn "  Install Strawberry Perl: https://strawberryperl.com"
} else {
    Success "Perl found: $($perl.Source)"
}

# -- Auto-detect Meson + Ninja (required by pg >= 17) --------
$mesonCmd = Get-Command meson -ErrorAction SilentlyContinue
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $mesonCmd) {
    Warn "meson not found -- pg >= 17 builds will fail."
    Warn "  Install with: pip install meson  or  choco install meson"
}
if (-not $ninjaCmd) {
    Warn "ninja not found -- pg >= 17 builds will fail."
    Warn "  Install with: choco install ninja  or  winget install Ninja-build.Ninja"
}
if ($mesonCmd -and $ninjaCmd) {
    Success "Meson found : $($mesonCmd.Source)"
    Success "Ninja found : $($ninjaCmd.Source)"
}

# -- Auto-detect OpenSSL -------------------------------------
# $opensslDir    = root install dir (for includes)
# $opensslLibDir = subdir that actually contains libssl.lib / libcrypto.lib
#
# Different OpenSSL Win64 installers place import libs in different spots:
#   Shining Light release layout  : <root>\lib\
#   Shining Light VC/MD layout    : <root>\lib\VC\x64\MD\
#   Shining Light VC/MDd layout   : <root>\lib\VC\x64\MDd\
#   Some older installers         : <root>\lib\VC\
$opensslDir    = $null
$opensslLibDir = $null

$opensslRoots = @(
    "C:\Program Files\OpenSSL-Win64",
    "C:\Program Files\OpenSSL",
    "C:\OpenSSL-Win64",
    "C:\OpenSSL"
)
$opensslLibSubs = @("lib", "lib\VC\x64\MD", "lib\VC\x64\MDd", "lib\VC")

$foundOpenssl = $false
foreach ($root in $opensslRoots) {
    if ($foundOpenssl) { break }
    foreach ($sub in $opensslLibSubs) {
        $candidate = Join-Path $root $sub
        if (Test-Path (Join-Path $candidate "libssl.lib")) {
            $opensslDir    = $root
            $opensslLibDir = $candidate
            $foundOpenssl  = $true
            break
        }
    }
}

if ($opensslDir) {
    Info "Found OpenSSL at   : $opensslDir"
    Info "OpenSSL lib dir    : $opensslLibDir"

    # PostgreSQL's Solution.pm always links against <opensslDir>\lib\libssl.lib
    # The Shining Light installer places libs in a sub-folder (lib\VC\x64\MD\ etc.)
    # Copy them up to lib\ so the linker finds them at the expected path.
    $opensslRootLib = Join-Path $opensslDir "lib"
    New-Item -ItemType Directory -Path $opensslRootLib -Force | Out-Null
    foreach ($libFile in @("libssl.lib","libcrypto.lib","libssl_static.lib","libcrypto_static.lib")) {
        $src = Join-Path $opensslLibDir $libFile
        $dst = Join-Path $opensslRootLib $libFile
        if ((Test-Path $src) -and (-not (Test-Path $dst))) {
            Copy-Item $src $dst -Force
            Info "Copied $libFile -> $opensslRootLib"
        }
    }

    $env:INCLUDE = "$opensslDir\include;$env:INCLUDE"
    $env:LIB     = "$opensslRootLib;$opensslLibDir;$env:LIB"
} else {
    Warn "OpenSSL not found -- building without it."
    Warn "  Install with: choco install openssl"
    Warn "  Or download Win64 installer from: https://slproweb.com/products/Win32OpenSSL.html"
}

# -- Auto-detect ICU (required by PostgreSQL >= 16) ----------
# ICU ships versioned libs: icuuc78.lib, icuin78.lib, icudt78.lib etc.
# We probe all candidate roots and lib sub-dirs for any icuuc*.lib match.
$icuDir    = $null
$icuLibDir = $null

$icuRoots = @(
    "C:\icu",
    "C:\icu4c",
    "C:\Program Files\icu"
)
$chocoIcu = "C:\ProgramData\chocolatey\lib\icu\tools"
if (Test-Path $chocoIcu) { $icuRoots = @($chocoIcu) + $icuRoots }
$icuLibSubs = @("lib64", "lib")

$foundIcu = $false
foreach ($root in $icuRoots) {
    if ($foundIcu) { break }
    foreach ($sub in $icuLibSubs) {
        $candidate = Join-Path $root $sub
        # Match versioned names like icuuc78.lib, icuuc76.lib, etc.
        $probe = Get-ChildItem -Path $candidate -Filter "icuuc*.lib" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($probe) {
            $icuDir    = $root
            $icuLibDir = $candidate
            $foundIcu  = $true
            break
        }
    }
}

if ($icuDir) {
    Info "Found ICU at  : $icuDir"
    Info "ICU lib dir   : $icuLibDir"
    $env:INCLUDE = "$icuDir\include;$env:INCLUDE"
    $env:LIB     = "$icuLibDir;$env:LIB"
} else {
    Warn "ICU not found -- pg16+ will build with --without-icu."
    Warn "  Install with: choco install icu"
    Warn "  Or download from: https://github.com/unicode-org/icu/releases"
}

# -- Collect archives ----------------------------------------
$archives = Get-ChildItem -Path $SourceDir -Filter "postgresql-*.tar.gz" |
            Where-Object { -not $_.PSIsContainer -and $_.DirectoryName -eq $SourceDir } |
            Sort-Object Name

if ($archives.Count -eq 0) {
    Err "No postgresql-*.tar.gz files found in '$SourceDir'."
    exit 1
}

Info "Found $($archives.Count) archive(s):"
$archives | ForEach-Object { Write-Host "    $($_.Name)" }

# -- Track results -------------------------------------------
$built  = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()

# ============================================================
# Main loop
# ============================================================
foreach ($archive in $archives) {
    # Parse version from filename  e.g. postgresql-16.3.tar.gz -> 16.3
    $version = $null
    if ($archive.Name -match 'postgresql-(\d+\.\d+(?:\.\d+)?)') {
        $version = $Matches[1]
    } else {
        Err "Could not parse version from '$($archive.Name)'. Skipping."
        $failed.Add($archive.Name); continue
    }

    $logDir     = Join-Path $LogBase $version
    $extractDir = Join-Path $SourceDir "postgresql-$version"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Header "Building PostgreSQL $version"

    # -- 1. Extract ----------------------------------------------
    Info "Extracting $($archive.Name)..."
    try {
        # tar is available on Windows 10 1803+ and Server 2019+
        & tar -xzf $archive.FullName -C $SourceDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "tar exited with code $LASTEXITCODE" }
    } catch {
        Err "Extraction failed: $_"
        $failed.Add($version); continue
    }

    # Tolerate postgresql-16 vs postgresql-16.3 unpacking differences
    if (-not (Test-Path $extractDir)) {
        $major = $version.Split(".")[0]
        $extractDir = Get-ChildItem -Path $SourceDir -Directory -Filter "postgresql-$major*" |
                      Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
    }

    if (-not $extractDir -or -not (Test-Path $extractDir)) {
        Err "Could not find extracted directory for $($archive.Name). Skipping."
        $failed.Add($version); continue
    }
    Success "Extracted -> $extractDir"

    Push-Location $extractDir

    $major = [int]($version.Split(".")[0])

    # -- 2 & 3. Build -- strategy depends on pg version ----------
    # pg <= 16 : legacy MSVC build  (src\tools\msvc\mkvcbuild.pl + MSBuild)
    # pg >= 17 : Meson + Ninja
    if ($major -ge 17) {

        # -- 2a. Meson setup -----------------------------------------
        Info "Configuring with Meson (pg $major)..."
        $configLog = Join-Path $logDir "configure.log"
        $buildDir  = Join-Path $extractDir "build"

        # Build meson option list
        # Correct Meson option names for PostgreSQL:
        #   ssl  = openssl | none     (NOT -Dopenssl=)
        #   icu  = auto | enabled | disabled
        # On Windows, pkg-config usually won't find OpenSSL/ICU, so we
        # pass extra_lib_dirs / extra_include_dirs explicitly.
        $mesonOpts = @(
            "--prefix=$extractDir\install",
            "--buildtype=release"
        )
        # Collect include/lib dirs from all deps, then pass once as comma-separated lists
        $extraIncludes = @()
        $extraLibs     = @()

        if ($opensslDir) {
            $mesonOpts      += "-Dssl=openssl"
            $extraIncludes  += "$opensslDir\include"
            $extraLibs      += $opensslRootLib
        } else {
            $mesonOpts += "-Dssl=none"
        }
        if ($icuDir) {
            $mesonOpts     += "-Dicu=enabled"
            $extraIncludes += "$icuDir\include"
            $extraLibs     += $icuLibDir
        } else {
            $mesonOpts += "-Dicu=disabled"
        }
        if ($extraIncludes.Count -gt 0) {
            $mesonOpts += ("-Dextra_include_dirs=" + ($extraIncludes -join ","))
        }
        if ($extraLibs.Count -gt 0) {
            $mesonOpts += ("-Dextra_lib_dirs=" + ($extraLibs -join ","))
        }

        try {
            $meson = Get-Command meson -ErrorAction Stop
            Info "  meson : $($meson.Source)"
            # Use & with an array -- PowerShell quotes each element correctly,
            # so paths containing spaces (e.g. "C:\Program Files\...") are safe.
            $mesonArgs = @("setup", $buildDir) + $mesonOpts
            & $meson.Source @mesonArgs 2>&1 | Tee-Object -FilePath $configLog | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "meson setup exited with code $LASTEXITCODE"
            }
        } catch {
            Err "Meson setup failed: $_"
            Err "  Log: $configLog"
            if (Test-Path $configLog) {
                Get-Content $configLog -Tail 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            }
            $failed.Add($version); Pop-Location; continue
        }
        Success "Meson configuration complete."

        # -- 3a. Ninja build -----------------------------------------
        Info "Running Ninja -j $Jobs..."
        $makeLog = Join-Path $logDir "make.log"
        try {
            $ninja = Get-Command ninja -ErrorAction Stop
            Info "  ninja : $($ninja.Source)"
            & $ninja.Source -C $buildDir -j $Jobs 2>&1 | Tee-Object -FilePath $makeLog | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Ninja exited with code $LASTEXITCODE"
            }
        } catch {
            Err "Ninja build failed: $_"
            Err "  Log: $makeLog"
            if (Test-Path $makeLog) {
                Get-Content $makeLog -Tail 30 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
            }
            $failed.Add($version); Pop-Location; continue
        }

    } else {

        # -- 2b. Generate config.pl then run mkvcbuild.pl (pg <= 16) -
        # PostgreSQL's MSVC build system does NOT accept command-line flags.
        # Dependencies are declared in src\tools\msvc\config.pl.
        Info "Generating src\tools\msvc\config.pl..."
        $configPlPath = "src\tools\msvc\config.pl"

        if (-not (Test-Path "src\tools\msvc")) {
            Err "src\tools\msvc not found in $extractDir -- unexpected archive layout."
            $failed.Add($version); Pop-Location; continue
        }

        $configLines = @()
        $configLines += "# Auto-generated by build_postgres.ps1"
        $configLines += "our `$config = {"

        if ($opensslDir) {
            $opensslPerl = $opensslDir -replace '\\', '/'
            $configLines += "    openssl  => '$opensslPerl',"
            Info "config.pl: openssl => $opensslPerl"
        }

        if ($major -ge 16) {
            if ($icuDir) {
                $icuPerl = $icuDir -replace '\\', '/'
                $configLines += "    icu      => '$icuPerl',"
                Info "config.pl: icu => $icuPerl"
            } else {
                $configLines += "    icu      => undef,"
                Info "config.pl: icu => undef (not found)"
            }
        }

        $configLines += "};"
        $configLines += "1;"
        $configLines | Set-Content -Encoding ASCII $configPlPath

        Info "Running mkvcbuild.pl..."
        $configLog = Join-Path $logDir "configure.log"
        try {
            if (-not (Test-Path "src\tools\msvc\mkvcbuild.pl")) {
                throw "mkvcbuild.pl not found -- extraction may have failed"
            }
            Info "  cwd          : $(Get-Location)"
            Info "  mkvcbuild.pl : $(Resolve-Path 'src\tools\msvc\mkvcbuild.pl')"
            Info "  config.pl    : $(Resolve-Path $configPlPath)"

            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName  = (Get-Command perl -ErrorAction Stop).Source
            $pinfo.Arguments = "src\tools\msvc\mkvcbuild.pl"
            $pinfo.WorkingDirectory       = (Get-Location).Path
            $pinfo.RedirectStandardOutput = $true
            $pinfo.RedirectStandardError  = $true
            $pinfo.UseShellExecute        = $false

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stdout = $proc.StandardOutput.ReadToEnd()
            $stderr = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            "$stdout`n$stderr" | Set-Content -Encoding UTF8 $configLog

            if ($proc.ExitCode -ne 0) { throw "mkvcbuild.pl exited with code $($proc.ExitCode)" }
        } catch {
            Err "mkvcbuild.pl failed: $_"
            Err "  Log: $configLog"
            $tail = Get-Content $configLog -Tail 20
            if ($tail) { $tail | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
            else { Warn "  Log empty -- check: perl -c src\tools\msvc\mkvcbuild.pl" }
            $failed.Add($version); Pop-Location; continue
        }
        Success "Solution generated."

        # -- 3b. MSBuild (pg <= 16) ----------------------------------
        Info "Running MSBuild /m:$Jobs..."
        $makeLog = Join-Path $logDir "make.log"
        try {
            $msbuild = Get-Command msbuild -ErrorAction Stop
            & $msbuild pgsql.sln /m:$Jobs /p:Configuration=Release /p:Platform=x64 `
                /nologo /verbosity:minimal *> $makeLog
            if ($LASTEXITCODE -ne 0) { throw "MSBuild exited with code $LASTEXITCODE" }
        } catch {
            Err "MSBuild failed -- see $makeLog"
            $failed.Add($version); Pop-Location; continue
        }

    } # end version dispatch

    Success "Build complete."
    Pop-Location
    $built.Add($version)
}



# ============================================================
# Summary
# ============================================================
Header "Summary"

if ($built.Count  -gt 0) { Success "Built  ($($built.Count)):  $($built -join ', ')" }
if ($failed.Count -gt 0) { Err     "Failed ($($failed.Count)): $($failed -join ', ')" }

Write-Host "`nLogs saved to: $LogBase"

if ($failed.Count -gt 0) { exit 1 }
Write-Host ""
Success "All versions built successfully."