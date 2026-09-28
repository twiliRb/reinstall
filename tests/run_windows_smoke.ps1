$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot '..\reinstall.bat'
$sourcePattern = "raw.githubusercontent.com/twiliRb/reinstall/$($env:REINSTALL_SOURCE_COMMIT)/lib/reinstall-cmdline.sh"
$testSshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHj7Ml2PQbt9pkYbcXn6axzAP2ZKZh0PTLg1dp8R5ROy ci@reinstall'
$cases = @(
    @{
        Name = 'AlmaLinux'
        Arguments = @('--username', 'x', '--password', 'x', 'almalinux')
        Checkpoints = @("source=$sourcePattern", 'selection=SET FINALOS ALMALINUX', 'next-os=SET NEXTOS ALPINE 3.24', 'network=NETWORK INFO', 'boot-entry=ADD EFI ENTRY IN WINDOWS')
    },
    @{
        Name = 'Ubuntu'
        Arguments = @('--username', 'x', '--password', 'x', 'ubuntu')
        Checkpoints = @("source=$sourcePattern", 'selection=SET FINALOS UBUNTU 26.04', 'image=File type: qemu', 'next-os=SET NEXTOS ALPINE 3.24', 'network=NETWORK INFO', 'boot-entry=ADD EFI ENTRY IN WINDOWS')
    },
    @{
        Name = 'Debian'
        Arguments = @('--username', 'x', '--password', 'x', 'debian')
        Checkpoints = @("source=$sourcePattern", 'next-os=SET NEXTOS DEBIAN 13', 'network=NETWORK INFO', 'boot-entry=ADD EFI ENTRY IN WINDOWS')
    },
    @{
        Name = 'Debian cloud-init network, SSH key and ext4'
        Arguments = @('--username', 'x', '--ssh-key', $testSshKey, '--ssh-port', '2222', '--filesystem', 'ext4', '--ip-mode', 'dhcp', '--dns-mode', 'static', '--dns-servers', '1.1.1.1', 'debian', '--ci')
        Checkpoints = @("source=$sourcePattern", 'next-os=SET NEXTOS DEBIAN 13', 'network=NETWORK INFO', 'ssh-key=Public Key: ssh-ed25519', 'ssh-port=SSH Port: 2222', 'boot-entry=ADD EFI ENTRY IN WINDOWS')
    },
    @{
        Name = 'netboot.xyz'
        Arguments = @('netboot.xyz')
        Checkpoints = @('target=SET NEXTOS NETBOOT.XYZ', 'image-url=https://boot.netboot.xyz/ipxe/netboot.xyz.efi', 'boot-entry=ADD EFI ENTRY IN WINDOWS')
    },
    @{
        Name = 'Debian image'
        Arguments = @('--username', 'x', '--password', 'x', 'dd', '--img=https://cloud.debian.org/images/cloud/sid/daily/latest/debian-sid-nocloud-amd64-daily.tar.xz')
        Checkpoints = @("source=$sourcePattern", 'selection=SET FINALOS DD', 'image=File type: raw.tar.xz', 'firmware=DD: Image is EFI.')
    },
    @{
        Name = 'Windows image and remote-access ports'
        Arguments = @('--username', 'x', '--password', 'x', '--ssh-port', '2222', '--rdp-port', '3390', '--web-port', '8080', 'windows', '--image-name=Windows Server blah', '--iso', 'https://aka.ms/HCIReleaseImage')
        Checkpoints = @("source=$sourcePattern", 'selection=SET FINALOS WINDOWS', 'image=File type: iso', 'ssh-port=SSH Port: 2222', 'rdp-port=RDP Port: 3390', 'web-log=WEB: http://IP:8080')
    },
    @{
        Name = 'Reset'
        Arguments = @('reset')
        Checkpoints = @('reset=reset done.')
    }
)

foreach ($case in $cases) {
    $log = [System.IO.Path]::GetTempFileName()
    try {
        Write-Output "RUN $($case.Name)"
        $arguments = $case.Arguments
        & $installer @arguments *> $log
        $status = $LASTEXITCODE

        if ($status -eq 0) {
            foreach ($checkpoint in $case.Checkpoints) {
                $separator = $checkpoint.IndexOf('=')
                if ($separator -lt 1) {
                    Write-Output "FAIL $($case.Name): malformed checkpoint $checkpoint"
                    $status = 2
                    break
                }

                $stage = $checkpoint.Substring(0, $separator)
                $pattern = $checkpoint.Substring($separator + 1)
                $matched = Get-Content -LiteralPath $log |
                    Where-Object { $_.Contains($pattern) } |
                    Select-Object -First 1
                if ($null -eq $matched) {
                    Write-Output "FAIL $($case.Name): checkpoint $stage missing ($pattern)"
                    $status = 1
                    break
                }
                Write-Output "CHECKPOINT $($case.Name)/${stage}: $matched"
            }
        }

        if ($status -ne 0) {
            Write-Output "FAIL $($case.Name) (exit $status)"
            Get-Content -LiteralPath $log | Write-Output
            exit $status
        }

        Write-Output "PASS $($case.Name)"
    }
    finally {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}
