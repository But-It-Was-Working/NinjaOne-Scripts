<#
.SYNOPSIS
    Grants a user temporary local administrator rights (5 / 15 / 30 minutes),
    then automatically revokes them. Built to run from NinjaOne as SYSTEM.

.DESCRIPTION
    Action = Grant
      1. Resolves the target user (explicit Username, or the user logged on at the console).
      2. Refuses if the user is already a local admin (we never remove rights we didn't grant).
      3. Adds the user's SID to the local Administrators group (S-1-5-32-544, language-independent).
      4. Copies this script to a locked-down folder (SYSTEM + Administrators only) and registers
         a SYSTEM scheduled task that runs "-Action Revoke" at expiry, and at startup as a failsafe.
      5. Writes a state file + optional NinjaOne custom field, and notifies the user.

    Action = Revoke
      Removes every grant whose expiry has passed (or all grants with -Force / when run manually
      from NinjaOne), optionally logs the user off, deletes the scheduled task, and cleans up.

    HOW THE USER USES THE RIGHTS (no logoff needed):
      Right-click the installer -> "Run as administrator" -> enter THEIR OWN username + password
      in the UAC prompt. That creates a fresh logon token, which picks up the new group membership
      immediately. Logging off/on also works, but leaves the whole desktop session elevated until
      the next logoff, so the UAC route is safer and faster.

.PARAMETER Action
    Grant or Revoke. NinjaOne script variable: "action" (dropdown).

.PARAMETER DurationMinutes
    5, 15 or 30. NinjaOne script variable: "durationMinutes" (dropdown).

.PARAMETER Username
    Optional. DOMAIN\user, AzureAD\user@domain.com, or a local account name. Blank = console user.
    NinjaOne script variable: "targetUser" (text).

.PARAMETER LogoffOnExpiry
    If set, the user is logged off when rights expire, so any token that picked up admin via
    logoff/logon is discarded. NinjaOne script variable: "logoffOnExpiry" (checkbox).

.PARAMETER CustomField
    Optional NinjaOne device custom field (text) to record status in. Default: tempAdminStatus.
    Ignored if the field doesn't exist.

.PARAMETER Force
    With Revoke: revoke all active grants immediately regardless of expiry.

.NOTES
    Author:   But-It-Was-Working (https://github.com/But-It-Was-Working/NinjaOne-Scripts)
    Date:     2026-11-17
    Version:  1.0
    Run As:   SYSTEM (NinjaOne)
    Log:      C:\ProgramData\TempLocalAdmin\TempLocalAdmin.log
    Exit codes: 0 success, 1 failure, 2 user already admin / nothing to do
#>

[CmdletBinding()]
param(
    [ValidateSet('Grant', 'Revoke')]
    [string]$Action,

    [ValidateSet(5, 15, 30)]
    [int]$DurationMinutes,

    [string]$Username,

    [switch]$LogoffOnExpiry,

    [string]$CustomField = 'tempAdminStatus',

    [switch]$Force,

    # Internal: set by the scheduled task so a timed revoke only removes expired grants.
    [switch]$Scheduled
)

#region Configuration
$Script:BaseDir   = Join-Path $env:ProgramData 'TempLocalAdmin'
$Script:StateFile = Join-Path $Script:BaseDir 'grants.json'
$Script:LogFile   = Join-Path $Script:BaseDir 'TempLocalAdmin.log'
$Script:LocalCopy = Join-Path $Script:BaseDir 'Invoke-TempLocalAdmin.ps1'
$Script:TaskName  = 'TempLocalAdmin-Revoke'
$Script:AdminSid  = 'S-1-5-32-544'
#endregion

#region NinjaOne script variables (environment variables override defaults when params not passed)
if (-not $PSBoundParameters.ContainsKey('Action') -and $env:action)                  { $Action = $env:action }
if (-not $PSBoundParameters.ContainsKey('DurationMinutes') -and $env:durationMinutes) { $DurationMinutes = [int]$env:durationMinutes }
# NOTE: the Ninja variable is "targetUser", NOT "username" - $env:USERNAME is a built-in Windows variable.
if (-not $PSBoundParameters.ContainsKey('Username') -and $env:targetUser)            { $Username = $env:targetUser }
if (-not $PSBoundParameters.ContainsKey('LogoffOnExpiry') -and $env:logoffOnExpiry -eq 'true') { $LogoffOnExpiry = $true }
if (-not $PSBoundParameters.ContainsKey('Force') -and $env:force -eq 'true')         { $Force = $true }
if (-not $Action)          { $Action = 'Grant' }
if (-not $DurationMinutes) { $DurationMinutes = 15 }
if ($DurationMinutes -notin 5, 15, 30) {
    Write-Output "ERROR: DurationMinutes must be 5, 15 or 30 (got '$DurationMinutes')."
    exit 1
}
#endregion

#region Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Output $entry   # Ninja captures stdout in the activity log
    try { Add-Content -Path $Script:LogFile -Value $entry -ErrorAction Stop } catch { }
}

function Initialize-BaseDir {
    # Locked-down folder: only SYSTEM and Administrators. Standard users can't swap the revoke script.
    if (-not (Test-Path $Script:BaseDir)) {
        New-Item -Path $Script:BaseDir -ItemType Directory -Force | Out-Null
    }
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', $Script:AdminSid) {
        $id   = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $id, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -Path $Script:BaseDir -AclObject $acl
}

function Get-State {
    if (Test-Path $Script:StateFile) {
        try { return @(Get-Content $Script:StateFile -Raw | ConvertFrom-Json) } catch { }
    }
    return @()
}

function Save-State {
    param([object[]]$Grants)
    if ($Grants.Count -eq 0) {
        Remove-Item $Script:StateFile -Force -ErrorAction SilentlyContinue
    } else {
        ConvertTo-Json -InputObject @($Grants) -Depth 3 | Set-Content -Path $Script:StateFile -Encoding UTF8
    }
}

function Get-ConsoleUser {
    # Win32_ComputerSystem.UserName = console session user (DOMAIN\user or AzureAD\user)
    $u = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($u) { return $u }
    # Fallback: owner of explorer.exe (covers some RDP/fast-user-switch cases)
    $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
    if ($explorer) {
        $o = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        if ($o.ReturnValue -eq 0) { return "$($o.Domain)\$($o.User)" }
    }
    return $null
}

function Resolve-UserSid {
    param([string]$Name)
    # AzureAD accounts: translate via the "AzureAD\" prefix; the NTAccount API handles DOMAIN\user and local names.
    try {
        return (New-Object System.Security.Principal.NTAccount($Name)).Translate(
            [System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        # Try the logged-on user's profile list as a last resort (e.g. AzureAD UPN form)
        $leaf = ($Name -split '\\')[-1]
        $prof = Get-CimInstance Win32_UserProfile | Where-Object {
            $_.LocalPath -and ((Split-Path $_.LocalPath -Leaf) -ieq ($leaf -split '@')[0])
        } | Select-Object -First 1
        if ($prof) { return $prof.SID }
        return $null
    }
}

function Get-AdminGroup {
    # ADSI handles AzureAD / orphaned SIDs better than Get-LocalGroupMember (which errors with 1789).
    $name = (New-Object System.Security.Principal.SecurityIdentifier($Script:AdminSid)).Translate(
        [System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    return @{ Name = $name; Adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$name,group" }
}

function Get-AdminMemberSids {
    $grp = (Get-AdminGroup).Adsi
    $sids = foreach ($m in $grp.psbase.Invoke('Members')) {
        try {
            $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
            (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
        } catch { }
    }
    return @($sids)
}

function Test-IsAdminMember {
    param([string]$Sid)
    return (Get-AdminMemberSids) -contains $Sid
}

function Add-AdminMember {
    param([string]$Sid, [string]$Name)
    $grp = Get-AdminGroup
    try {
        $grp.Adsi.Add("WinNT://$Sid")
    } catch {
        Write-Log "ADSI add failed ($($_.Exception.Message)); falling back to net.exe" 'WARN'
        & net.exe localgroup "$($grp.Name)" "$Name" /add | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "net localgroup add failed for $Name (exit $LASTEXITCODE)" }
    }
}

function Remove-AdminMember {
    param([string]$Sid, [string]$Name)
    $grp = Get-AdminGroup
    try {
        $grp.Adsi.Remove("WinNT://$Sid")
    } catch {
        Write-Log "ADSI remove failed ($($_.Exception.Message)); falling back to net.exe" 'WARN'
        & net.exe localgroup "$($grp.Name)" "$Name" /delete | Out-Null
    }
    if (Test-IsAdminMember $Sid) { throw "User $Name ($Sid) is STILL in Administrators after removal attempt." }
}

function Send-UserMessage {
    param([string]$Text)
    try { & msg.exe * /TIME:120 $Text 2>$null } catch { }
}

function Set-NinjaStatus {
    param([string]$Text)
    if (-not $CustomField) { return }
    try {
        if (Get-Command Ninja-Property-Set -ErrorAction SilentlyContinue) {
            Ninja-Property-Set $CustomField $Text 2>$null | Out-Null
        }
    } catch { }
}

function Register-RevokeTask {
    param([datetime]$At)
    if ($PSCommandPath -ine $Script:LocalCopy) {
        Copy-Item -Path $PSCommandPath -Destination $Script:LocalCopy -Force
    }
    $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script:LocalCopy`" -Action Revoke -Scheduled"
    $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $psArgs
    $triggers   = @(
        (New-ScheduledTaskTrigger -Once -At $At),
        (New-ScheduledTaskTrigger -AtStartup)          # failsafe if the device reboots mid-window
    )
    $principal  = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings   = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $Script:TaskName -Action $taskAction -Trigger $triggers `
        -Principal $principal -Settings $settings -Force | Out-Null
}

function Invoke-UserLogoff {
    param([string]$Name)
    $leaf = ($Name -split '\\')[-1]
    $sessions = & quser.exe 2>$null | Select-Object -Skip 1
    foreach ($line in $sessions) {
        $cols = ($line.Trim() -replace '^>', '') -split '\s+'
        if ($cols[0] -ieq $leaf -or $cols[0] -ieq ($leaf -split '@')[0]) {
            $id = ($cols | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)
            if ($id) {
                Write-Log "Logging off session $id for $Name"
                & logoff.exe $id 2>$null
            }
        }
    }
}
#endregion

#region Main
try {
    Initialize-BaseDir
} catch {
    Write-Output "ERROR: could not prepare $Script:BaseDir : $($_.Exception.Message)"
    exit 1
}

if ($Action -eq 'Grant') {
    if (-not $Username) { $Username = Get-ConsoleUser }
    if (-not $Username) {
        Write-Log 'No Username given and nobody is logged on at the console.' 'ERROR'
        exit 1
    }

    $sid = Resolve-UserSid $Username
    if (-not $sid) {
        Write-Log "Could not resolve a SID for '$Username'." 'ERROR'
        exit 1
    }
    if ($sid -like 'S-1-5-21-*-500') {
        Write-Log "Refusing to manage the built-in Administrator account." 'ERROR'
        exit 1
    }

    $grants   = @(Get-State)
    $existing = $grants | Where-Object { $_.Sid -eq $sid }

    if (-not $existing -and (Test-IsAdminMember $sid)) {
        Write-Log "$Username is already a local administrator (not via this tool). Nothing to do; will not schedule removal." 'WARN'
        exit 2
    }

    $expiry = (Get-Date).AddMinutes($DurationMinutes)

    try {
        if (-not (Test-IsAdminMember $sid)) { Add-AdminMember -Sid $sid -Name $Username }
    } catch {
        Write-Log "Failed to add $Username to Administrators: $($_.Exception.Message)" 'ERROR'
        exit 1
    }

    # Record/extend grant, then schedule revoke for the latest expiry of all active grants
    $grants = @($grants | Where-Object { $_.Sid -ne $sid })
    $grants += [pscustomobject]@{
        Username       = $Username
        Sid            = $sid
        GrantedAt      = (Get-Date).ToString('o')
        ExpiresAt      = $expiry.ToString('o')
        LogoffOnExpiry = [bool]$LogoffOnExpiry
        GrantedBy      = 'NinjaOne'
    }
    Save-State $grants

    $nextRun = ($grants | ForEach-Object { [datetime]$_.ExpiresAt } | Sort-Object | Select-Object -First 1)
    try {
        Register-RevokeTask -At $nextRun
    } catch {
        Write-Log "Could not register revoke task ($($_.Exception.Message)). Rolling back grant." 'ERROR'
        try { Remove-AdminMember -Sid $sid -Name $Username } catch { }
        Save-State @($grants | Where-Object { $_.Sid -ne $sid })
        exit 1
    }

    $expText = $expiry.ToString('HH:mm')
    Write-Log "GRANTED: $Username ($sid) is a local admin for $DurationMinutes min, until $expText." 'SUCCESS'
    Set-NinjaStatus "Admin granted to $Username until $($expiry.ToString('yyyy-MM-dd HH:mm'))"
    Send-UserMessage ("You have temporary administrator rights for $DurationMinutes minutes (until $expText).`n`n" +
        "To install or update: right-click the installer and choose 'Run as administrator', " +
        "then sign in with YOUR OWN username and password.`n`n" +
        "Rights are removed automatically at $expText.")
    exit 0
}

if ($Action -eq 'Revoke') {
    $grants = @(Get-State)
    if ($grants.Count -eq 0) {
        Write-Log 'No active temporary admin grants recorded.'
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-NinjaStatus 'No active grant'
        exit 0
    }

    # Manual run from NinjaOne (not -Scheduled) = revoke everything now.
    $revokeAll = $Force -or -not $Scheduled
    $now       = Get-Date
    $remaining = @()
    $failed    = $false

    foreach ($g in $grants) {
        if (-not $revokeAll -and [datetime]$g.ExpiresAt -gt $now) { $remaining += $g; continue }
        try {
            if (Test-IsAdminMember $g.Sid) { Remove-AdminMember -Sid $g.Sid -Name $g.Username }
            Write-Log "REVOKED: $($g.Username) ($($g.Sid)) removed from Administrators." 'SUCCESS'
            if ($g.LogoffOnExpiry) {
                Send-UserMessage 'Your temporary administrator rights have ended. You will be signed out in 60 seconds - please save your work.'
                Start-Sleep -Seconds 60
                Invoke-UserLogoff $g.Username
            } else {
                Send-UserMessage 'Your temporary administrator rights have ended.'
            }
        } catch {
            Write-Log "Failed to revoke $($g.Username): $($_.Exception.Message)" 'ERROR'
            $remaining += $g
            $failed = $true
        }
    }

    Save-State $remaining
    if ($remaining.Count -eq 0) {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Set-NinjaStatus "Revoked $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    } else {
        # Grants still pending (or a removal failed): reschedule. Failures retry in 5 minutes.
        $next = ($remaining | ForEach-Object { [datetime]$_.ExpiresAt } | Sort-Object | Select-Object -First 1)
        if ($failed -or $next -le (Get-Date)) { $next = (Get-Date).AddMinutes(5) }
        try { Register-RevokeTask -At $next } catch { Write-Log "Could not reschedule revoke task: $($_.Exception.Message)" 'ERROR' }
        Set-NinjaStatus "Revoke pending/retry at $($next.ToString('yyyy-MM-dd HH:mm'))"
    }
    if ($failed) { exit 1 } else { exit 0 }
}
#endregion
