#Requires -Modules Pester

<#
.SYNOPSIS
    Pester v5 tests for BR-PreJob-VMShutdown.ps1

.DESCRIPTION
    Tests all logic paths with fully mocked Veeam and VMware dependencies.
    The script is transformed at load time: exit→return so it can be called
    as a function. Uses public Veeam cmdlets only (console-compatible).
#>

Describe 'BR-PreJob-VMShutdown' {

    BeforeAll {
        $ScriptPath = Join-Path $PSScriptRoot 'BR-PreJob-VMShutdown.ps1'
        $raw = Get-Content $ScriptPath -Raw

        #region --- Transform script into a testable function ---

        $paramIdx = $raw.IndexOf('Param(')
        $body = $raw.Substring($paramIdx)

        # Wrap in function
        $body = "function Invoke-PreJobShutdown {`n$body`n}"

        # Relax mandatory params for testing
        $body = $body -replace 'Mandatory\s*=\s*\$true', 'Mandatory = $false'

        # exit N → return N
        $body = $body -replace '(?m)^(\s*)exit\s+(\d+)\s*$', '$1return $2'

        #endregion

        #region --- Stub functions for cmdlets absent in test env ---

        function Connect-VBRServer     { [CmdletBinding()] param([string]$Server) }
        function Disconnect-VBRServer  { [CmdletBinding()] param() }
        function Get-VBRJob            { [CmdletBinding()] param([string]$Name) }
        function Get-VBRJobObject      { [CmdletBinding()] param($Job) }
        function Get-VBRServer         { [CmdletBinding()] param([string]$Type) }
        function Connect-VIServer      { [CmdletBinding()] param([string]$Server, $Credential, [string]$User, [string]$Password, [switch]$Force) }
        function Disconnect-VIServer   { [CmdletBinding()] param($Server, [switch]$Confirm) }
        function Set-PowerCLIConfiguration { [CmdletBinding()] param($InvalidCertificateAction, $ParticipateInCEIP, [switch]$Confirm) }
        function Shutdown-VMGuest      { [CmdletBinding()] param($VM, [switch]$Confirm) }
        function Stop-VM               { [CmdletBinding()] param($VM, [switch]$Confirm) }
        function Get-Folder            { [CmdletBinding()] param([string]$Name) }
        function Get-ResourcePool      { [CmdletBinding()] param([string]$Name) }
        function Get-VApp              { [CmdletBinding()] param([string]$Name) }
        function Get-Tag               { [CmdletBinding()] param([string]$Name) }
        function Get-VM                { [CmdletBinding()] param([string]$Name, $Location, $Tag) }

        #endregion

        #region --- Load transformed function ---
        . ([ScriptBlock]::Create($body))
        #endregion

        #region --- Helper factories ---

        function New-MockVM {
            param(
                [string]$Name,
                [string]$PowerState = 'PoweredOn',
                [string]$ToolsStatus = 'toolsOk'
            )
            [PSCustomObject]@{
                Name          = $Name
                PowerState    = $PowerState
                ExtensionData = [PSCustomObject]@{
                    Guest = [PSCustomObject]@{ ToolsStatus = $ToolsStatus }
                }
            }
        }

        function New-MockJob {
            param([string]$Name = 'TestBackupJob')
            [PSCustomObject]@{ Name = $Name }
        }

        function New-MockJobObject {
            param(
                [string]$Name,
                [string]$Type = 'VM'
            )
            [PSCustomObject]@{
                Object = [PSCustomObject]@{
                    Name = $Name
                    Type = $Type
                }
            }
        }

        function New-MockVCServer {
            param([string]$Name = 'vcenter.lab.local')
            $vc = [PSCustomObject]@{ Name = $Name }
            $vc | Add-Member -MemberType ScriptMethod -Name GetCredentials -Value {
                return [PSCustomObject]@{ UserName = 'admin@vsphere.local'; Password = 'P@ss' }
            }
            return $vc
        }

        #endregion
    }

    BeforeEach {
        # --- Common default mocks ---
        Mock Import-Module {}
        Mock Set-PowerCLIConfiguration {}
        Mock Write-Host {}
        Mock Start-Sleep {}
        Mock Connect-VBRServer {}
        Mock Disconnect-VBRServer {}
        Mock Disconnect-VIServer {}
        Mock Shutdown-VMGuest {}
        Mock Stop-VM {}
        Mock Get-Folder {}
        Mock Get-ResourcePool {}
        Mock Get-VApp {}
        Mock Get-Tag {}

        # Default: one healthy VM, valid job, one vCenter
        $script:defaultVM  = New-MockVM -Name 'TestVM' -PowerState 'PoweredOn' -ToolsStatus 'toolsOk'
        $script:defaultJob = New-MockJob -Name 'TestBackupJob'

        Mock Get-VBRJob        { return $script:defaultJob }
        Mock Get-VBRJobObject  { return @(New-MockJobObject -Name 'TestVM' -Type 'VM') }
        Mock Get-VBRServer     { return @(New-MockVCServer) }
        Mock Connect-VIServer  { [PSCustomObject]@{ Name = $Server; IsConnected = $true } }
        Mock Get-VM            { return $script:defaultVM }
    }

    # ================================================================
    # VBR connection
    # ================================================================

    Context 'VBR connection' {

        It 'exits 1 when VBR connection fails' {
            Mock Connect-VBRServer { throw 'connection refused' }

            $result = Invoke-PreJobShutdown -JobName 'MyJob'
            $result | Should -Be 1
        }

        It 'connects to specified VBR server' {
            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob' -VBRServer 'vbr.lab.local'
            Should -Invoke Connect-VBRServer -Times 1 -ParameterFilter { $Server -eq 'vbr.lab.local' }
        }
    }

    # ================================================================
    # Job resolution
    # ================================================================

    Context 'Job resolution' {

        It 'exits 1 when job name not found' {
            Mock Get-VBRJob { return $null }

            $result = Invoke-PreJobShutdown -JobName 'NonExistentJob'
            $result | Should -Be 1
        }

        It 'proceeds when job is found by name' {
            $onVM  = New-MockVM -Name 'TestVM' -PowerState 'PoweredOn' -ToolsStatus 'toolsOk'
            $offVM = New-MockVM -Name 'TestVM' -PowerState 'PoweredOff'

            $script:q = [System.Collections.Queue]::new()
            $script:q.Enqueue($onVM)   # VM enumeration
            $script:q.Enqueue($onVM)   # refresh in shutdown loop
            $script:q.Enqueue($offVM)  # poll → off
            Mock Get-VM {
                if ($script:q.Count -gt 0) { return $script:q.Dequeue() }
                return $offVM
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            Should -Invoke Get-VBRJob -Times 1 -ParameterFilter { $Name -eq 'TestBackupJob' }
            $result | Should -Be 0
        }
    }

    # ================================================================
    # vCenter connectivity
    # ================================================================

    Context 'vCenter connectivity' {

        It 'exits 1 when no vCenter servers registered in VBR' {
            Mock Get-VBRServer { return @() }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 1
        }

        It 'connects using explicit -vCenterServer parameter' {
            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob' -vCenterServer 'myvc.local'
            Should -Invoke Connect-VIServer -Times 1 -ParameterFilter { $Server -eq 'myvc.local' }
        }

        It 'exits 1 when explicit vCenter connection fails' {
            Mock Connect-VIServer { throw 'connection refused' }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob' -vCenterServer 'bad.host'
            $result | Should -Be 1
        }
    }

    # ================================================================
    # VM already PoweredOff
    # ================================================================

    Context 'VM already PoweredOff' {

        It 'skips the VM — no shutdown issued — exits 0' {
            $offVM = New-MockVM -Name 'OffVM' -PowerState 'PoweredOff'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'OffVM' -Type 'VM') }
            Mock Get-VM { return $offVM }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Shutdown-VMGuest -Times 0
            Should -Invoke Stop-VM -Times 0
        }
    }

    # ================================================================
    # VM with VMware Tools running — graceful shutdown
    # ================================================================

    Context 'VM with Tools running (toolsOk)' {

        It 'calls Shutdown-VMGuest, polls until PoweredOff, exits 0' {
            $onVM  = New-MockVM -Name 'RunVM' -PowerState 'PoweredOn'  -ToolsStatus 'toolsOk'
            $offVM = New-MockVM -Name 'RunVM' -PowerState 'PoweredOff' -ToolsStatus 'toolsOk'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'RunVM' -Type 'VM') }

            $script:q = [System.Collections.Queue]::new()
            $script:q.Enqueue($onVM)   # VM enumeration
            $script:q.Enqueue($onVM)   # refresh in shutdown loop
            $script:q.Enqueue($offVM)  # first poll → off
            Mock Get-VM {
                if ($script:q.Count -gt 0) { return $script:q.Dequeue() }
                return $offVM
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Shutdown-VMGuest -Times 1
        }

        It 'treats toolsOld as tools-available (graceful shutdown)' {
            $onVM  = New-MockVM -Name 'OldVM' -PowerState 'PoweredOn'  -ToolsStatus 'toolsOld'
            $offVM = New-MockVM -Name 'OldVM' -PowerState 'PoweredOff'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'OldVM' -Type 'VM') }

            $script:q = [System.Collections.Queue]::new()
            $script:q.Enqueue($onVM)
            $script:q.Enqueue($onVM)
            $script:q.Enqueue($offVM)
            Mock Get-VM {
                if ($script:q.Count -gt 0) { return $script:q.Dequeue() }
                return $offVM
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Shutdown-VMGuest -Times 1
            Should -Invoke Stop-VM -Times 0
        }
    }

    # ================================================================
    # VM with Tools NOT running — skip or force
    # ================================================================

    Context 'VM with Tools not running (toolsNotRunning)' {

        It 'skips VM when -ForceShutdown is not set — exits 0' {
            $vm  = New-MockVM -Name 'NoToolsVM' -PowerState 'PoweredOn' -ToolsStatus 'toolsNotRunning'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'NoToolsVM' -Type 'VM') }
            Mock Get-VM { return $vm }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Shutdown-VMGuest -Times 0
            Should -Invoke Stop-VM -Times 0
        }
    }

    Context 'VM with Tools not installed (toolsNotInstalled) + ForceShutdown' {

        It 'calls Stop-VM (hard power-off) and exits 0' {
            $onVM  = New-MockVM -Name 'NoToolsVM' -PowerState 'PoweredOn' -ToolsStatus 'toolsNotInstalled'
            $offVM = New-MockVM -Name 'NoToolsVM' -PowerState 'PoweredOff'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'NoToolsVM' -Type 'VM') }

            $script:q = [System.Collections.Queue]::new()
            $script:q.Enqueue($onVM)   # VM enumeration
            $script:q.Enqueue($onVM)   # refresh
            $script:q.Enqueue($offVM)  # poll → off
            Mock Get-VM {
                if ($script:q.Count -gt 0) { return $script:q.Dequeue() }
                return $offVM
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob' -ForceShutdown
            $result | Should -Be 0
            Should -Invoke Stop-VM -Times 1
            Should -Invoke Shutdown-VMGuest -Times 0
        }
    }

    # ================================================================
    # Shutdown timeout
    # ================================================================

    Context 'Shutdown timeout' {

        It 'adds VM to failedVMs and exits 1 when VM never powers off' {
            $vm  = New-MockVM -Name 'StuckVM' -PowerState 'PoweredOn' -ToolsStatus 'toolsOk'
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'StuckVM' -Type 'VM') }
            Mock Get-VM { return $vm }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob' -ShutdownTimeoutSeconds 10
            $result | Should -Be 1
            Should -Invoke Shutdown-VMGuest -Times 1
        }
    }

    # ================================================================
    # Multiple VMs — all succeed
    # ================================================================

    Context 'All VMs power off successfully' {

        It 'exits 0 when two VMs both shut down' {
            $vm1on  = New-MockVM -Name 'VM1' -PowerState 'PoweredOn'  -ToolsStatus 'toolsOk'
            $vm1off = New-MockVM -Name 'VM1' -PowerState 'PoweredOff'
            $vm2on  = New-MockVM -Name 'VM2' -PowerState 'PoweredOn'  -ToolsStatus 'toolsOk'
            $vm2off = New-MockVM -Name 'VM2' -PowerState 'PoweredOff'

            Mock Get-VBRJobObject { return @(
                (New-MockJobObject -Name 'VM1' -Type 'VM'),
                (New-MockJobObject -Name 'VM2' -Type 'VM')
            ) }

            $script:q = [System.Collections.Queue]::new()
            # VM enumeration
            $script:q.Enqueue($vm1on)
            $script:q.Enqueue($vm2on)
            # Shutdown loop: VM1 refresh → poll off
            $script:q.Enqueue($vm1on)
            $script:q.Enqueue($vm1off)
            # Shutdown loop: VM2 refresh → poll off
            $script:q.Enqueue($vm2on)
            $script:q.Enqueue($vm2off)

            Mock Get-VM {
                if ($script:q.Count -gt 0) { return $script:q.Dequeue() }
                return $null
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Shutdown-VMGuest -Times 2
        }
    }

    # ================================================================
    # Container resolution: Folder
    # ================================================================

    Context 'Folder container type resolves VMs via Get-Folder' {

        It 'finds VMs via Get-Folder + Get-VM -Location' {
            $folderVM = New-MockVM -Name 'FolderVM' -PowerState 'PoweredOff'
            $folder   = [PSCustomObject]@{ Name = 'MyFolder'; Type = 'Folder' }
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'MyFolder' -Type 'Folder') }

            Mock Get-VM {
                if ($Location) { return $folderVM }
                return $folderVM
            }
            Mock Get-Folder { return $folder } -ParameterFilter { $Name -eq 'MyFolder' }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Get-Folder -Times 1
        }
    }

    # ================================================================
    # Container resolution: Tag
    # ================================================================

    Context 'Tag container type resolves VMs via Get-Tag' {

        It 'finds VMs via Get-Tag + Get-VM -Tag' {
            $tagVM = New-MockVM -Name 'TaggedVM' -PowerState 'PoweredOff'
            $tag   = [PSCustomObject]@{ Name = 'BackupTag'; Category = 'Backup' }
            Mock Get-VBRJobObject { return @(New-MockJobObject -Name 'BackupTag' -Type 'Tag') }
            Mock Get-Tag { return $tag } -ParameterFilter { $Name -eq 'BackupTag' }
            Mock Get-VM {
                if ($Tag) { return $tagVM }
                return $tagVM
            }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
            Should -Invoke Get-Tag -Times 1
        }
    }

    # ================================================================
    # No VMs found in job
    # ================================================================

    Context 'No VMs found in job' {

        It 'exits 0 gracefully when job has no objects' {
            Mock Get-VBRJobObject { return @() }

            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            $result | Should -Be 0
        }
    }

    # ================================================================
    # Disconnect cleanup
    # ================================================================

    Context 'Cleanup' {

        It 'disconnects from VBR server on success' {
            $result = Invoke-PreJobShutdown -JobName 'TestBackupJob'
            Should -Invoke Disconnect-VBRServer -Times 1
        }
    }
}
