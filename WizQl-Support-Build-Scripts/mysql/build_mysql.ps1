# =============================================================================
# build_mysql.ps1
# Extracts, configures (CMake), and builds all MySQL .tar.gz archives in a folder.
#
# Prerequisites:
#   - Visual Studio 2019/2022 with "Desktop development with C++" workload
#   - CMake              : winget install Kitware.CMake
#   - Bison + m4         : choco install winflexbison3
#   - OpenSSL (optional) : choco install openssl
#   - Git (for tar)      : winget install Git.Git
#                          (Git ships tar.exe -- make sure Git\usr\bin is in PATH)
#
# Usage:
#   .\build_mysql.ps1 [-SourceDir <path>]
#   SourceDir   Folder containing mysql-*.tar.gz  (default: current dir)
#
# Run from a "x64 Native Tools Command Prompt for VS" or the script will
# attempt to locate and invoke vcvarsall.bat automatically.
# =============================================================================

param(
    [string]$SourceDir = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Colour helpers ────────────────────────────────────────────────────────────
function Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Success { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Err     { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Header  { param($msg)
    Write-Host ""
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $msg"                                     -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════" -ForegroundColor Cyan
}

# ── Config knobs (edit as needed) ─────────────────────────────────────────────
$Jobs           = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$ExtraCMakeFlags = @("-DWITH_DEBUG=1", "-DWITH_ZLIB=bundled")

# ── Resolve source dir ────────────────────────────────────────────────────────
$SourceDir = Resolve-Path $SourceDir -ErrorAction Stop | Select-Object -ExpandProperty Path
$LogBase   = Join-Path $SourceDir "logs"

Info "Source dir : $SourceDir"
Info "Build dir  : $SourceDir"
Info "Jobs       : $Jobs"

# ── Auto-initialize MSVC environment if not already set ──────────────────────
if (-not $env:VCINSTALLDIR) {
    Info "MSVC environment not detected -- searching for vcvarsall.bat..."
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vsWhere) {
        $vsPath = & $vsWhere -latest -property installationPath 2>$null
        $vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvarsall.bat"
        if (Test-Path $vcvars) {
            Info "Found: $vcvars"
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
            Warn "vcvarsall.bat not found. Install Visual Studio with the C++ workload."
        }
    } else {
        Warn "vswhere.exe not found. Install Visual Studio 2019 or later."
    }
}

# ── Check for CMake ───────────────────────────────────────────────────────────
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmake) {
    Err "cmake not found. Install it with: winget install Kitware.CMake"
    exit 1
}
Info "CMake: $((& cmake --version)[0])"

# ── Check for Bison ───────────────────────────────────────────────────────────
# MySQL's parser generator requires bison. winflexbison3 (Chocolatey) installs
# win_bison.exe -- MySQL's CMake looks for both 'bison' and 'win_bison'.
$bison = Get-Command bison -ErrorAction SilentlyContinue
$winBison = Get-Command win_bison -ErrorAction SilentlyContinue
if (-not $bison -and -not $winBison) {
    Warn "bison / win_bison not found -- MySQL build may fail."
    Warn "  Install with: choco install winflexbison3"
} else {
    $bisonExe = if ($bison) { $bison } else { $winBison }
    Info "Bison: $($bisonExe.Source)"
}

# ── Check for tar (needed to extract .tar.gz) ─────────────────────────────────
# Windows 10 1803+ ships tar.exe in System32. Git for Windows also bundles it.
$tarCmd = Get-Command tar -ErrorAction SilentlyContinue
if (-not $tarCmd) {
    Err "tar not found. Install Git for Windows (winget install Git.Git) or update Windows."
    exit 1
}

# ── Auto-detect OpenSSL ───────────────────────────────────────────────────────
$opensslDir = $null
$opensslCandidates = @(
    "C:\Program Files\OpenSSL-Win64",
    "C:\Program Files\OpenSSL",
    "C:\OpenSSL-Win64",
    "C:\OpenSSL"
)
$chocoOpenssl = "C:\ProgramData\chocolatey\lib\openssl\tools\OpenSSL"
if (Test-Path $chocoOpenssl) { $opensslCandidates = @($chocoOpenssl) + $opensslCandidates }

foreach ($c in $opensslCandidates) {
    if (Test-Path (Join-Path $c "lib\libssl.lib")) {
        $opensslDir = $c; break
    }
}

if ($opensslDir) {
    Info "Found OpenSSL at: $opensslDir"
} else {
    Warn "OpenSSL not found -- building with bundled SSL."
    Warn "  Install with: choco install openssl"
    Warn "  Or download from: https://slproweb.com/products/Win32OpenSSL.html"
}

# ── Collect archives ──────────────────────────────────────────────────────────
$archives = Get-ChildItem -Path $SourceDir -MaxDepth 1 -Filter "mysql-*.tar.gz" |
            Sort-Object Name

if ($archives.Count -eq 0) {
    Err "No mysql-*.tar.gz files found in '$SourceDir'."
    exit 1
}

Info "Found $($archives.Count) archive(s):"
$archives | ForEach-Object { Write-Host "    $($_.Name)" }

# ── Track results ─────────────────────────────────────────────────────────────
$built  = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[string]]::new()

# ══════════════════════════════════════════════════════════════════════════════
# Main loop
# ══════════════════════════════════════════════════════════════════════════════
foreach ($archive in $archives) {
    $version = $null
    if ($archive.Name -match 'mysql-(\d+\.\d+(?:\.\d+)?)') {
        $version = $Matches[1]
    } else {
        Err "Could not parse version from '$($archive.Name)'. Skipping."
        $failed.Add($archive.Name); continue
    }

    $logDir     = Join-Path $LogBase $version
    $extractDir = Join-Path $SourceDir "mysql-$version"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    Header "Building MySQL $version"

    # ── 1. Extract ────────────────────────────────────────────────────────────
    Info "Extracting $($archive.Name)..."
    try {
        & tar -xzf $archive.FullName -C $SourceDir 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "tar exited with code $LASTEXITCODE" }
    } catch {
        Err "Extraction failed: $_"
        $failed.Add($version); continue
    }

    # Tolerate mysql-5 vs mysql-5.7.44 unpacking differences
    if (-not (Test-Path $extractDir)) {
        $major = $version.Split(".")[0]
        $extractDir = Get-ChildItem -Path $SourceDir -Directory -Filter "mysql-$major*" |
                      Sort-Object Name | Select-Object -Last 1 -ExpandProperty FullName
    }

    if (-not $extractDir -or -not (Test-Path $extractDir)) {
        Err "Could not find extracted directory. Skipping."
        $failed.Add($version); continue
    }
    Success "Extracted -> $extractDir"

    # Out-of-tree build dir
    $buildDir = Join-Path $extractDir "build"
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

    # ── 2. Assemble CMake flags ───────────────────────────────────────────────
    $boostDir = Join-Path $extractDir "boost"
    $cmakeFlags = [System.Collections.Generic.List[string]]@(
        "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
        "-DDOWNLOAD_BOOST=1",
        "-DWITH_BOOST=$boostDir",
        "-DWITH_UNIT_TESTS=OFF",
        # Use Ninja if available for faster builds, otherwise let CMake pick
        "-G", "Visual Studio 17 2022",
        "-A", "x64"
    )

    # Fall back to VS 2019 generator if 2022 is not installed
    $vs2022 = & $vsWhere -version "[17,18)" -property installationPath 2>$null
    if (-not $vs2022) {
        $cmakeFlags.Remove("-G"); $cmakeFlags.Remove("Visual Studio 17 2022")
        $cmakeFlags.AddRange([string[]]@("-G", "Visual Studio 16 2019"))
    }

    # SSL
    if ($opensslDir) {
        $cmakeFlags.Add("-DWITH_SSL=$opensslDir")
    } else {
        $cmakeFlags.Add("-DWITH_SSL=bundled")
    }

    # Extra flags from config knob
    foreach ($f in $ExtraCMakeFlags) { $cmakeFlags.Add($f) }

    # ── 3. CMake configure ────────────────────────────────────────────────────
    Info "Running cmake..."
    $cmakeLog = Join-Path $logDir "cmake.log"
    try {
        & cmake -S $extractDir -B $buildDir @cmakeFlags *> $cmakeLog
        if ($LASTEXITCODE -ne 0) { throw "cmake exited with code $LASTEXITCODE" }
    } catch {
        Err "cmake failed -- see $cmakeLog"
        $failed.Add($version); continue
    }
    Success "CMake configure done."

    # ── 4. Build ──────────────────────────────────────────────────────────────
    Info "Building with $Jobs jobs..."
    $makeLog = Join-Path $logDir "make.log"
    try {
        & cmake --build $buildDir --config RelWithDebInfo --parallel $Jobs *> $makeLog
        if ($LASTEXITCODE -ne 0) { throw "build exited with code $LASTEXITCODE" }
    } catch {
        Err "Build failed -- see $makeLog"
        $failed.Add($version); continue
    }
    Success "Build complete."

    # ── 4b. Build client tools explicitly ─────────────────────────────────────
    Info "Building client tools (mysqldump, mysqlcheck, mysqlimport, mysqlpump)..."
    $clientTools = @("mysqldump", "mysqlcheck", "mysqlimport")
    $majorMinor  = [double]($version.Split(".")[0..1] -join ".")
    if ($majorMinor -ge 5.7) { $clientTools += "mysqlpump" }

    foreach ($tool in $clientTools) {
        & cmake --build $buildDir --target $tool --config RelWithDebInfo --parallel $Jobs `
            >> $makeLog 2>&1
        if ($LASTEXITCODE -eq 0) {
            Success "  Built: $tool"
        } else {
            Warn "  Could not build $tool (may not exist in this version -- skipping)"
        }
    }

    $built.Add($version)
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
Header "Summary"

if ($built.Count  -gt 0) { Success "Built  ($($built.Count)):  $($built -join ', ')" }
if ($failed.Count -gt 0) { Err     "Failed ($($failed.Count)): $($failed -join ', ')" }

Write-Host "`nLogs saved to: $LogBase"

if ($failed.Count -gt 0) { exit 1 }
Write-Host ""
Success "All versions built successfully."
