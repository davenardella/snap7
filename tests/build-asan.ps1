<#
.SYNOPSIS
  Builds snap7.dll (Win32, ASan) and client_test.exe for one snap7 source tree.

.DESCRIPTION
  Test-only configuration, nothing here touches a vcxproj. The DLL is compiled directly
  with cl.exe from the sources of the tree, so the same script builds any snap7 revision.
  Output goes to tests\out\<Name>\:
    snap7.dll, client_test.exe, clang_rt.asan_dynamic-i386.dll

  The C header always comes from the repo of this script (release\wrappers\c-cpp).

  Settings: x86, /Od /Zi, /fsanitize=address, /MD (dynamic CRT, as the ASan runtime DLL
  needs it), no /RTC1, /INCREMENTAL:NO.

.EXAMPLE
  .\build-asan.ps1 -Tree C:\src\snap7-fixed -Name new
  .\build-asan.ps1 -Tree C:\src\snap7-upstream -Name old
#>
param(
    [Parameter(Mandatory)][string]$Tree,
    [Parameter(Mandatory)][string]$Name
)
$ErrorActionPreference = 'Stop'
$Tree = (Resolve-Path $Tree).Path
$here = $PSScriptRoot
$out = Join-Path $here "out\$Name"
New-Item -ItemType Directory -Force $out, "$out\obj" | Out-Null

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsRoot = & $vswhere -latest -products * -property installationPath
$vsDevCmd = Join-Path $vsRoot 'Common7\Tools\VsDevCmd.bat'

$sources = @(
    'src\core\s7_client.cpp', 'src\core\s7_isotcp.cpp', 'src\core\s7_micro_client.cpp',
    'src\core\s7_partner.cpp', 'src\core\s7_peer.cpp', 'src\core\s7_server.cpp',
    'src\core\s7_text.cpp', 'src\lib\snap7_libmain.cpp', 'src\sys\snap_msgsock.cpp',
    'src\sys\snap_sysutils.cpp', 'src\sys\snap_tcpsrvr.cpp', 'src\sys\snap_threads.cpp'
) | ForEach-Object { '"' + (Join-Path $Tree $_) + '"' }

$defs = '/DWIN32 /D_WINDOWS /D_USRDLL /D_CRT_SECURE_NO_WARNINGS /D_WINSOCK_DEPRECATED_NO_WARNINGS'
$inc = "/I`"$Tree\src\core`" /I`"$Tree\src\sys`" /I`"$Tree\src\lib`""
$common = '/nologo /Od /Zi /MD /EHsc /fsanitize=address /W3'

$dll = "cl $common $defs $inc /LD $($sources -join ' ') /Fo`"$out\obj/`" /Fd`"$out\snap7.pdb`" /Fe`"$out\snap7.dll`" " +
       "/link /DEF:`"$Tree\src\lib\snap7.def`" /INCREMENTAL:NO ws2_32.lib winmm.lib"
$exe = "cl $common /I`"$here\..\release\wrappers\c-cpp`" `"$here\client_test.cpp`" /Fo`"$out\obj/`" /Fd`"$out\client_test.pdb`" /Fe`"$out\client_test.exe`" " +
       "/link /INCREMENTAL:NO"

$cmdFile = Join-Path $out 'build.cmd'
@('@echo off', "call `"$vsDevCmd`" -arch=x86 -host_arch=x86 >nul", 'if errorlevel 1 exit /b 1',
  $dll, 'if errorlevel 1 exit /b 1', $exe, 'if errorlevel 1 exit /b 1') | Set-Content -Encoding ascii $cmdFile
& cmd.exe /c $cmdFile
if ($LASTEXITCODE -ne 0) { throw "build of '$Name' failed" }

# ASan runtime next to the binaries
$rt = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory | Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'bin\Hostx86\x86\clang_rt.asan_dynamic-i386.dll' } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $rt) { throw 'clang_rt.asan_dynamic-i386.dll not found' }
Copy-Item $rt $out -Force
Write-Host "built $out"
