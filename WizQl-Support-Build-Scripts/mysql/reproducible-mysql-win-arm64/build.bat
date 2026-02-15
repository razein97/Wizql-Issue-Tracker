@echo off

rem ******************************************************************************
rem USAGE:
rem   build.bat [vcvarsall arch]
rem
rem Where the arch is one of the following:
rem   arm64
rem   x64_arm64
rem ******************************************************************************
rem It is assumed that you have the following installed on your system:
rem   Visual Studio 2022 (17.3 or higher) incl 
rem     22000 SDK or higher
rem     ARM64 libs
rem   Perl
rem   Git
rem   
rem It is also assumed that the following is true
rem   You are using an ARM64 host machine
rem   You want a debug build (as most tests are disabled in release mode)
rem ******************************************************************************
rem In place of the equivalent of "set -e" in a shell script, we use "|| exit /b"
rem ******************************************************************************

setlocal

rem Set the various locations required by the script
set MYSQL_SERVER_DIR=%CD%\mysql-server
set MYSQL_SERVER_BUILD_DIR=%MYSQL_SERVER_DIR%\build
set OPENSSL_DIR=%CD%\openssl
set OPENSSL_INSTALL_DIR=%CD%\openssl-install
set WINFLEXBISON_DIR=%CD%\winflexbison
set WINFLEXBISON_INSTALL_DIR=%CD%\winflexbison-install
set CMAKE_INSTALL_DIR=%CD%\cmake-3.24.0-rc2-windows-arm64
set VCPKG_DIR=%CD%\vcpkg
set VCPKG_LIBEVENT_DIR=%VCPKG_DIR%\packages\libevent_arm64-windows
set VCVARSALL_PATH="C:\Program Files\Microsoft Visual Studio\2022\Preview\VC\Auxiliary\Build\vcvarsall.bat"
set BOOST_DIR=%CD%\boost-mysql

rem Ensure the first argument has been passed
if %1.==. (
  echo An argument specifying the vcvars arch must be given. Please read the comment at the top of the batch file!
  exit
)

if "%PROCESSOR_ARCHITECTURE%" neq "ARM64" (
  echo Must be run on an ARM64 host. Please read the comment at the top of the batch file!
  exit
)

if not exist "%MYSQL_SERVER_DIR%" (
  echo Cloning mysql-server
  git clone -b mysql-8.0.29 --depth 1 --single-branch https://github.com/mysql/mysql-server %MYSQL_SERVER_DIR% || exit /b
  
  rem Apply patches (not using am, as it errors out if no user is set for git, ie in a CI machine with a fresh env)
  pushd %MYSQL_SERVER_DIR%
  git apply --ignore-whitespace ..\0001-Add-secondary-method-of-checking-libevent-version.patch || exit /b
  git apply --ignore-whitespace ..\0002-Silence-C5257-warning.patch || exit /b
  git apply --ignore-whitespace ..\0003-Add-support-for-Windows-ARM64-builds.patch || exit /b
  git apply --ignore-whitespace ..\0004-Define-minimum-version-for-ARM64-Windows.patch || exit /b
  git apply --ignore-whitespace ..\0005-Add-check-for-clang-on-Windows-ARM64-platforms.patch || exit /b
  popd
)

if not exist "%OPENSSL_DIR%" (
  echo "Cloning openssl"
  git clone -b OpenSSL_1_1_1-stable --depth 1 --single-branch https://github.com/openssl/openssl %OPENSSL_DIR% || exit /b
)

if not exist %WINFLEXBISON_DIR% (
  echo Cloning winflexbison
  git clone -b master --depth 1 --single-branch https://github.com/lexxmark/winflexbison %WINFLEXBISON_DIR% || exit /b
)

rem We assume that if the vcpkg directory exists, it has been bootstrapped
if not exist "%VCPKG_DIR%" (
  echo Cloning vcpkg
  git clone -b master --depth 1 --single-branch https://github.com/microsoft/vcpkg %VCPKG_DIR% || exit /b
  pushd %VCPKG_DIR%
  call .\bootstrap-vcpkg.bat -disableMetric
  popd
)

rem Install libevent into vcpkg if it doesn't exist
if not exist "%VCPKG_LIBEVENT_DIR%" (
  pushd %VCPKG_DIR%
  vcpkg.exe install libevent:arm64-windows || exit /b
  popd
)

rem Download and install CMake
if not exist %CMAKE_INSTALL_DIR% (
  curl -L https://github.com/Kitware/CMake/releases/download/v3.24.0-rc2/cmake-3.24.0-rc2-windows-arm64.zip -o cmake.zip || exit /b
  tar -xf cmake.zip
)

rem ADD Arm64 CMake to the start of the path
set PATH=%CMAKE_INSTALL_DIR%\bin;%PATH%

rem Now we initialize the vcvarsall
call %VCVARSALL_PATH% %1

rem We have to set this after we call VCVARSALL, so that we can do delayed expansion in an if statement later
setlocal EnableDelayedExpansion

rem Fix Debug DLL Path
rem This fixes errors in ARM64 when using debug builds. See for more info: https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28677636097/Debug+run-time+DLL+issue
set PATH=%PATH%;%WindowsSdkVerBinPath%\arm64\ucrt;%VCToolsRedistDir%\onecore\debug_nonredist\arm64\Microsoft.VC143.DebugCRT

rem Build OpenSSL, and install it into the installation directory
rem We assume that if the installation directory exists, OpenSSL has been built and installed into it already, so we skip this step
if not exist "%OPENSSL_INSTALL_DIR%" (
  mkdir %OPENSSL_INSTALL_DIR%
  pushd %OPENSSL_DIR%
  perl Configure VC-WIN64-ARM --prefix=%OPENSSL_INSTALL_DIR% --openssldir=%OPENSSL_INSTALL_DIR% --debug || exit /b
  nmake || exit /b
  nmake install || exit /b
)

rem Build WinFlexBison, and install it into the installation directory
rem We assume that if the installation directory exists, WinFlexBison has been built and installed into it already, so we skip this step
if not exist %WINFLEXBISON_INSTALL_DIR% (
  rem Create the installation dir and push into it
  mkdir %WINFLEXBISON_INSTALL_DIR%
  pushd %WINFLEXBISON_INSTALL_DIR%
  rem Switch to the source dir
  pushd %WINFLEXBISON_DIR%
  rem Build WinFlexBison (for ARM64)
  mkdir build
  cd build
  cmake .. -A ARM64 -G "Visual Studio 17 2022" || exit /b
  cmake --build . --config "Release" --target package || exit /b
  popd
  rem Go back to the installation dir and unzip the build output, and rename produced exe files
  tar -xf %WINFLEXBISON_DIR%\build\win_flex_bison-master.zip
  move win_bison.exe bison.exe
  move win_flex.exe flex.exe
  popd
)

set PATH=%PATH%;%WINFLEXBISON_INSTALL_DIR%

rem We assume that CMake has *not* been run if there is no build dir, so we run it
if not exist %MYSQL_SERVER_BUILD_DIR% (
  mkdir %MYSQL_SERVER_BUILD_DIR%
  pushd %MYSQL_SERVER_BUILD_DIR%
  
  for /f "delims=" %%i in ('where cl') do set CL_PATH=%%i

  set MYSQL_EXTRA_CMAKE_ARGS=-DCMAKE_C_COMPILER="!CL_PATH!" -DCMAKE_CXX_COMPILER="!CL_PATH!"
  cmake .. -G "Visual Studio 17 2022" -A ARM64 -DWITH_BOOST="%BOOST_DIR%" -DDOWNLOAD_BOOST=1 -DCMAKE_TOOLCHAIN_FILE="%VCPKG_DIR%\scripts\buildsystems\vcpkg.cmake" -DWITH_SSL=%OPENSSL_INSTALL_DIR% !MYSQL_EXTRA_CMAKE_ARGS! || exit /b
  popd
)

rem Now we actually build mysql-server
pushd %MYSQL_SERVER_BUILD_DIR%

if "%VSCMD_ARG_HOST_ARCH%"=="arm64" (
  msbuild /p:Configuration=Debug /p:PreferredToolArchitecture=ARM64 /m MySQL.sln || exit /b
) else (
  msbuild /p:Configuration=Debug /m MySQL.sln || exit /b
)

popd

echo Done!

endlocal
