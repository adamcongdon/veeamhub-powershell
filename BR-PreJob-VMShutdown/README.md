# BR-PreJob-VMShutdown

Veeam Backup & Replication pre-job script that gracefully shuts down all VMs in a
backup job before the job runs, then validates they are powered off before allowing
the backup to proceed.

## Use Case

When backing up VMs that require application-consistent or crash-consistent backups
without relying on VSS/quiescing, you can use this script to guarantee VMs are
cleanly powered off before the backup starts.

## Requirements

- **Veeam Backup & Replication Console** (v12+) — the full VBR server is **not** required
- PowerShell 7.0 or later (`pwsh.exe`) — Veeam.Backup.PowerShell requires PS 7+
- VMware PowerCLI 13.x or later
- Network access to the VBR server (for `Connect-VBRServer`) and vCenter
- Uses only public Veeam PowerShell cmdlets (`Connect-VBRServer`, `Get-VBRJob`,
  `Get-VBRJobObject`, etc.) — no server-side .NET API dependencies

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `JobName` | Yes | — | Name of the Veeam backup job to enumerate VMs from. |
| `VBRServer` | No | `localhost` | Hostname or IP of the VBR server to connect to via `Connect-VBRServer`. |
| `ForceShutdown` | No | `$false` | When set, VMs without VMware Tools will be hard-powered-off via `Stop-VM`. Without this flag, those VMs are skipped with a warning. |
| `ShutdownTimeoutSeconds` | No | `300` | Seconds to wait per VM for power-off confirmation before marking as failed. |
| `vCenterServer` | No | — | Explicit vCenter hostname/IP. If omitted, uses all vCenter servers registered in VBR. |
| `vCenterCredential` | No | — | `PSCredential` for vCenter. If omitted, uses Veeam-managed credentials. |

## VM State Handling

| VM State | Behavior |
|----------|----------|
| Already powered off | Skipped (logged) |
| Powered on, Tools running | `Shutdown-VMGuest` (graceful OS shutdown) |
| Powered on, Tools not running | Skip with warning (or force if `-ForceShutdown`) |
| Powered on, Tools not installed | Skip with warning (or force if `-ForceShutdown`) |
| Does not power off within timeout | Marked as failed; job blocked (exit code 1) |

## Container Support

The script resolves all VM container types returned by `Get-VBRJobObject`:

- `VM` — individual virtual machines
- `Folder` — VMware folders (resolves contained VMs via `Get-VM -Location`)
- `ResourcePool` — VMware resource pools
- `VApp` — VMware vApps
- `Tag` — VMware tags (resolves tagged VMs via `Get-VM -Tag`)

## Configuring in Veeam

1. Copy the script folder to the machine with the Veeam Console (e.g., `C:\Scripts\BR-PreJob-VMShutdown\`)
2. Open the backup job → **Advanced Settings** → **Scripts**
3. Set **Pre-job script** to:

```
pwsh.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\BR-PreJob-VMShutdown\BR-PreJob-VMShutdown.ps1" -JobName "My Backup Job"
```

> **Note:** Use `pwsh.exe` (PowerShell 7), not `powershell.exe` (Windows PowerShell 5.1).
> The Veeam.Backup.PowerShell module requires PowerShell 7+.

4. To connect to a remote VBR server, add `-VBRServer "vbr.lab.local"`.
5. Optionally append `-ForceShutdown` to force-off VMs without VMware Tools.

### Full example with all options

```
pwsh.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\BR-PreJob-VMShutdown\BR-PreJob-VMShutdown.ps1" -JobName "My Backup Job" -VBRServer "vbr.lab.local" -ForceShutdown -ShutdownTimeoutSeconds 600
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All targeted VMs powered off — backup proceeds |
| `1` | One or more VMs failed to power off — backup is blocked |

## Authors

- Adam Congdon
