$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot '..\reinstall.bat'
$tracePrefix = '@REINSTALL_XTRACE@ '
$tracePattern = '^@+REINSTALL_XTRACE@ '
$env:PS4 = $tracePrefix
$cases = @(
    @{ Name = 'AlmaLinux'; Arguments = @('--debug', '--username', 'x', '--password', 'x', 'almalinux') },
    @{ Name = 'Ubuntu'; Arguments = @('--debug', '--username', 'x', '--password', 'x', 'ubuntu') },
    @{ Name = 'Debian'; Arguments = @('--debug', '--username', 'x', '--password', 'x', 'debian') },
    @{ Name = 'Debian cloud-init with network modes'; Arguments = @('--debug', '--username', 'x', '--password', 'x', '--ip-mode', 'dhcp', '--dns-mode', 'static', '--dns-servers', '1.1.1.1', 'debian', '--ci') },
    @{ Name = 'netboot.xyz'; Arguments = @('--debug', 'netboot.xyz') },
    @{ Name = 'Debian image'; Arguments = @('--debug', '--username', 'x', '--password', 'x', 'dd', '--img=https://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-nocloud-amd64-daily.tar.xz') },
    @{ Name = 'Windows image'; Arguments = @('--debug', '--username', 'x', '--password', 'x', 'windows', '--image-name=Windows Server blah', '--iso', 'https://aka.ms/HCIReleaseImage') },
    @{ Name = 'Reset'; Arguments = @('--debug', 'reset') }
)

foreach ($case in $cases) {
    $log = [System.IO.Path]::GetTempFileName()
    try {
        $arguments = $case.Arguments
        & $installer @arguments *> $log
        $status = $LASTEXITCODE
        if ($status -eq 0) {
            Write-Output "PASS $($case.Name)"
            $visibleOutput = @(Get-Content -LiteralPath $log | Where-Object { $_ -notmatch $tracePattern })
            if ($visibleOutput.Count -gt 0) {
                Write-Output "OUTPUT $($case.Name)"
                $visibleOutput | Write-Output
            }
            continue
        }

        Write-Output "FAIL $($case.Name) (exit $status)"
        Get-Content -LiteralPath $log | Write-Host
        exit $status
    }
    finally {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}
