<#
.SYNOPSIS
    One line: what the script does.

.DESCRIPTION
    A few lines: how it works and what it changes on the device.

.PARAMETER Example
    What this input does. NinjaOne script variable: "example" (String).

.NOTES
    Author:     <your GitHub name>
    Source:     https://github.com/But-It-Was-Working/NinjaOne-Scripts
    Version:    1.0
    Run As:     System | Current Logged on User
    Exit codes: 0 success, 1 failure
#>

[CmdletBinding()]
param(
    [string]$Example
)

#region NinjaOne script variables
# NinjaOne passes script variables as environment variables. A -Parameter passed on the
# command line wins, so the script can also be tested from a console.
# Avoid names Windows already uses ($env:USERNAME, $env:COMPUTERNAME, $env:PATH, ...).
if (-not $PSBoundParameters.ContainsKey('Example') -and $env:example) { $Example = $env:example }
# Checkbox variables arrive as the string 'true' or 'false':
# if ($env:someCheckbox -eq 'true') { $SomeSwitch = $true }
#endregion

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    # Write-Output lines show up in the NinjaOne activity output.
    Write-Output ("[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
}

function Set-NinjaField {
    # Writes to a NinjaOne custom field when the script runs under the agent. Does nothing elsewhere.
    param([string]$Name, [string]$Value)
    if ($Name -and (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue)) {
        try { Ninja-Property-Set $Name $Value | Out-Null } catch { Write-Log "Could not set field '$Name': $($_.Exception.Message)" 'WARN' }
    }
}
#endregion

#region Main
try {
    Write-Log "Starting. Example = '$Example'"

    # ... do the work ...

    Write-Log 'Done.' 'SUCCESS'
    exit 0
} catch {
    Write-Log "Failed: $($_.Exception.Message)" 'ERROR'
    exit 1
}
#endregion
