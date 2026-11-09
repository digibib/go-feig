@echo off
REM Build feigshim.dll + feigshim.lib, the C shim around the MSVC-ABI
REM FEDM SDK (src/fedm_shim.cpp, exports per src/feigshim.def).
REM
REM Run this ONCE on a Windows box with Visual Studio 2022 (C++ build
REM tools). The zig windows cross build on Linux (make build_windows)
REM links feigshim.lib and stages feigshim.dll - commit the output dir
REM fedm\shim-windows\ back to the repo afterwards:
REM
REM   1. on Windows:  scripts\build-feigshim-windows.bat
REM   2. copy fedm\shim-windows\ back into the repo (it is committed)
REM   3. on Linux:    make build_windows
REM
REM Output:
REM   fedm\shim-windows\feigshim.dll
REM   fedm\shim-windows\feigshim.lib
REM   fedm\shim-windows\vcruntime140.dll
REM   fedm\shim-windows\vcruntime140_1.dll
REM   fedm\shim-windows\msvcp140.dll
REM
REM Written in goto style, no parenthesized blocks - cmd parses
REM parentheses in echo/REM text inside blocks as syntax, which breaks.
setlocal
cd /d "%~dp0.."

REM --- locate vcvarsall.bat ---
set "VSWHERE=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
set "VCVARS="
if not exist "%VSWHERE%" goto try_std

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSINSTALL=%%i"
if defined VSINSTALL if exist "%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=%VSINSTALL%\VC\Auxiliary\Build\vcvarsall.bat"

:try_std
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvarsall.bat" set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvarsall.bat"
if defined VCVARS goto found
goto fail

:fail
echo.
echo ERROR: could not locate vcvarsall.bat - MSVC not found where expected.
echo --- install dirs ---
dir /b "C:\Program Files (x86)\Microsoft Visual Studio" 2>nul
dir /b "C:\Program Files\Microsoft Visual Studio" 2>nul
echo If VS is on another drive, or installed without the C++ workload, adjust accordingly.
exit /b 1

:found
echo Using %VCVARS%
call "%VCVARS%" x64
where cl.exe >nul 2>nul
if errorlevel 1 goto no_cl

REM --- newest MSVC toolset (source of the VC runtime DLLs) ---
set "VCROOT=%VCVARS:\VC\Auxiliary\Build\vcvarsall.bat=%"
set "MSVCROOT="
for /d %%d in ("%VCROOT%\VC\Tools\MSVC\*") do set "MSVCROOT=%%d"
if not defined MSVCROOT goto fail_msvc
if not exist "%MSVCROOT%\bin\Hostx64\x64\vcruntime140.dll" goto fail_msvc

REM --- build the shim DLL ---
if not exist build\shimwin mkdir build\shimwin
if not exist fedm\shim-windows mkdir fedm\shim-windows

REM /MD keeps the dynamic CRT shared with the FEIG DLLs (same msvcp140.dll
REM heap, std::string safe across the boundary). /EHsc: fedm_shim.cpp uses
REM try/catch. /DFEDMDLL: consumer-side export/decorations of the SDK
REM headers that plain import-lib links need (same as the go msvccl build).
cl /nologo /LD /O2 /MD /EHsc /W3 /DFEDMDLL ^
  /I fedm\win-vc143-x64\include /I fedm\win-vc143-x64\include\fedm ^
  /Fo:build\shimwin\ ^
  /Fe:fedm\shim-windows\feigshim.dll ^
  src\fedm_shim.cpp ^
  /link /IMPLIB:fedm\shim-windows\feigshim.lib /DEF:src\feigshim.def ^
  fedm\win-vc143-x64\lib\release\fedm.lib ^
  fedm\win-vc143-x64\lib\release\feisp.lib ^
  fedm\win-vc143-x64\lib\release\fecom.lib ^
  fedm\win-vc143-x64\lib\release\fedm-service.lib ^
  fedm\win-vc143-x64\lib\release\fedm-config.lib ^
  fedm\win-vc143-x64\lib\release\fedm-funit.lib ^
  fedm\win-vc143-x64\lib\release\feudp.lib ^
  fedm\win-vc143-x64\lib\release\fetls.lib ^
  fedm\win-vc143-x64\lib\release\feusb.lib ^
  fedm\win-vc143-x64\lib\release\feble.lib
if errorlevel 1 goto fail_cl

REM --- stage the VC runtime DLLs (shipped with the deploy unit) ---
copy /y "%MSVCROOT%\bin\Hostx64\x64\vcruntime140.dll" fedm\shim-windows\ >nul
copy /y "%MSVCROOT%\bin\Hostx64\x64\vcruntime140_1.dll" fedm\shim-windows\ >nul
copy /y "%MSVCROOT%\bin\Hostx64\x64\msvcp140.dll" fedm\shim-windows\ >nul

echo.
echo Built fedm\shim-windows\ (feigshim.dll + feigshim.lib + VC runtime DLLs).
echo Commit fedm\shim-windows\, then on Linux:  make build_windows
goto done

:fail_cl
echo.
echo ERROR: cl failed - see errors above.
exit /b 1

:no_cl
echo ERROR: cl.exe not found on PATH after vcvarsall.
exit /b 1

:fail_msvc
echo ERROR: could not find the MSVC toolset (VC\Tools\MSVC) or the VC runtime DLLs in it.
exit /b 1

:done
endlocal
