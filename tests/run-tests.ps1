<#
.SYNOPSIS
  Runs every rogue_plc.py scenario against the ASan builds of the old and the new snap7.dll.

.DESCRIPTION
  Needs tests\out\old and tests\out\new (see build-asan.ps1). For each scenario a rogue_plc.py
  is started on a loopback port, then client_test.exe of each build runs against it. Logs go to
  tests\out\logs\<scenario>.<build>.txt (client output incl. ASan report) and
  tests\out\logs\<scenario>.server.txt; a summary table is printed and written to
  tests\out\summary.txt.
#>
param(
    [string]$Python = 'python',
    [int]$Port = 10102,
    [int]$TimeoutSec = 30,
    [string[]]$Builds = @('old', 'new'),
    [string[]]$Only = @()
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$logs = Join-Path $here 'out\logs'
New-Item -ItemType Directory -Force $logs | Out-Null

# name, rogue_plc.py mode/sequence arguments, list of client runs (each run = one process = one connection)
$scenarios = @(
    @{ Name = 'normal';       Srv = @('--mode', 'normal');       Runs = @(, @('connect', 'read:100', 'read:1000', 'write:100', 'write:1000', 'cpuinfo', 'status')) },
    @{ Name = 'read_big';     Srv = @('--mode', 'read_big');     Runs = @(, @('connect', 'read:100')) },
    @{ Name = 'read_claim';   Srv = @('--mode', 'read_claim');   Runs = @(, @('connect', 'read:100')) },
    @{ Name = 'read_short';   Srv = @('--mode', 'read_short');   Runs = @(, @('connect', 'read:100')) },
    @{ Name = 'neg_big';      Srv = @('--mode', 'neg_big');      Runs = @(, @('connect', 'write:5000', 'read:100')) },
    @{ Name = 'neg_short';    Srv = @('--mode', 'neg_short');    Runs = @(, @('connect', 'read:100', 'write:100')) },
    @{ Name = 'neg_long';     Srv = @('--mode', 'neg_long');     Runs = @(, @('connect', 'read:100', 'write:100')) },
    @{ Name = 'frag';         Srv = @('--mode', 'frag');         Runs = @(, @('connect', 'read:100')) },
    @{ Name = 'frag3';        Srv = @('--mode', 'frag3');        Runs = @(, @('connect', 'read:100', 'write:100')) },
    @{ Name = 'seq';          Srv = @('--mode', 'seq');          Runs = @(, @('connect', 'read:100', 'write:100', 'status')) },
    @{ Name = 'szl_big';      Srv = @('--mode', 'szl_big');      Runs = @(, @('connect', 'cpuinfo')) },
    @{ Name = 'szl_endless';  Srv = @('--mode', 'szl_endless');  Runs = @(, @('connect', 'status')) },
    @{ Name = 'szl_endless0'; Srv = @('--mode', 'szl_endless0'); Runs = @(, @('connect', 'status')) },
    # T3: three rogue connections in a row, then the same server answers correctly
    @{ Name = 'recovery';     Srv = @('--sequence', 'read_big,seq,normal');
       Runs = @(@('connect', 'read:100'), @('connect', 'read:100', 'write:100'), @('connect', 'read:100', 'write:100', 'cpuinfo', 'status')) }
)

# Waits for the "listening" line in the server log. Connecting to the port as a probe
# would consume the first entry of a --sequence.
function Wait-Server([string]$logFile) {
    for ($i = 0; $i -lt 100; $i++) {
        if ((Test-Path $logFile) -and (Select-String -Path $logFile -Pattern 'listening' -Quiet)) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "server did not come up ($logFile)"
}

function Invoke-Client([string]$build, [string[]]$ops, [string]$logFile) {
    $dir = Join-Path $here "out\$build"
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $dir 'client_test.exe'
    $psi.Arguments = (@($Port) + $ops) -join ' '
    $psi.WorkingDirectory = $dir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['ASAN_OPTIONS'] = 'detect_leaks=0:symbolize=1'
    $p = [Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { $p.Kill(); $p.WaitForExit() }
    $text = "ops: $($ops -join ' ')`r`n" + $so.Result + $se.Result
    if ($timedOut) { $text += "`r`nTIMEOUT after $TimeoutSec s (killed)" }
    Add-Content -Path $logFile -Value $text
    $asan = $null
    if ($text -match 'ERROR: AddressSanitizer: (\S+)') {
        $asan = $Matches[1]
        $frame = ($text -split "`r?`n" | Where-Object { $_ -match '^\s+#\d+ .* in .*(S7|snap|Snap|client_test)' } | Select-Object -First 1)
        if ($frame) { $asan += ' @ ' + ($frame -replace '^\s+#\d+ 0x[0-9a-f]+ in ', '' -replace ' [A-Za-z]:\\.*[\\/]', ' ') }
    }
    $codes = ($text -split "`r?`n" | Select-String -Pattern '^(ConnectTo|ReadArea|WriteArea|GetCpuInfo|PlcStatus)\s*(\(\d+\))?\s+rc=0x([0-9A-F]+)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value + $_.Matches[0].Groups[2].Value + '=' + $_.Matches[0].Groups[3].Value }) -join ' '
    [pscustomobject]@{ Asan = $asan; Codes = $codes; Timeout = $timedOut; Exit = $p.ExitCode }
}

$rows = @()
foreach ($s in $scenarios) {
    if ($Only.Count -and ($Only -notcontains $s.Name)) { continue }
    $srvLog = Join-Path $logs "$($s.Name).server.txt"
    Remove-Item "$logs\$($s.Name).*.txt" -ErrorAction SilentlyContinue
    foreach ($b in $Builds) {
        # one server per build so that the connection sequence starts fresh
        $srv = Start-Process -FilePath $Python -ArgumentList (@("`"$here\rogue_plc.py`"", '--port', $Port) + $s.Srv) `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $srvLog.Replace('.server.txt', ".$b.server.txt") `
            -RedirectStandardError ($srvLog.Replace('.server.txt', ".$b.server.err.txt"))
        try {
            Wait-Server $srvLog.Replace('.server.txt', ".$b.server.txt")
            $log = Join-Path $logs "$($s.Name).$b.txt"
            $results = @()
            foreach ($run in $s.Runs) { $results += Invoke-Client $b $run $log }
            $rows += [pscustomobject]@{
                Scenario = $s.Name; Build = $b
                Result = ($results | ForEach-Object {
                    if ($_.Asan) { "ASan: $($_.Asan)" } elseif ($_.Timeout) { "TIMEOUT ($($_.Codes))" } else { $_.Codes } }) -join ' | '
            }
        } finally {
            Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 300
        }
    }
}
$rows | Format-List | Out-String -Width 400 | Tee-Object -FilePath (Join-Path $here 'out\summary.txt')
