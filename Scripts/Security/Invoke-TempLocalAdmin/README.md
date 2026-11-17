# Temporary Local Admin (NinjaOne)

`Invoke-TempLocalAdmin.ps1` gives a user local admin rights for **5, 15 or 30 minutes**, then takes them away automatically.

## How it works

| Step | What happens |
|---|---|
| Grant | The user's SID is added to the local **Administrators** group (looked up by SID `S-1-5-32-544`, so it works on any OS language). |
| Timer | The script copies itself to `C:\ProgramData\TempLocalAdmin` (only SYSTEM and Administrators can access it) and registers the SYSTEM task **TempLocalAdmin-Revoke**. The task runs at expiry, again at startup (in case the device reboots during the window), and when the device wakes if it slept through the expiry time. |
| Revoke | The user is removed from Administrators, gets a message, and is optionally logged off. The task then deletes itself. |
| Safety | If the user is already an admin, the script does nothing and won't schedule a removal (exit 2). The built-in Administrator account (RID 500) is never touched. If the task can't be created, the grant is rolled back. |

## Better than logging off and on

The user does **not** need to log off. Tell them:

> Right-click the installer → **Run as administrator** → sign in with **your own** username and password.

A UAC credential prompt creates a fresh logon, which picks up the new group membership immediately. Only that one installer runs elevated. Their desktop stays a standard user.

Logging off and on also works, but then the whole session stays elevated until they log off again, even after the group membership is removed. Tick **Log off on expiry** when you expect them to use that route.

> Windows Hello PIN sign-in can't be used in this prompt. They need their actual password. AzureAD-joined users type `AzureAD\user@domain.com`.

## NinjaOne setup

**Administration → Library → Automation → Add → New Script**

- Language: PowerShell. Operating system: Windows. Architecture: All. **Run As: System**
- Paste in `Invoke-TempLocalAdmin.ps1`
- Script variables:

| Name | Type | Values / default |
|---|---|---|
| `action` | Drop-down | `Grant` (default), `Revoke` |
| `durationMinutes` | Drop-down | `5`, `15` (default), `30` |
| `targetUser` | String | Optional. Leave blank to use the console user. |
| `logoffOnExpiry` | Checkbox | Unchecked |

Don't name the variable `username`. `$env:USERNAME` is a built-in Windows variable and would return the SYSTEM account.

Optional: create a device custom field **`tempAdminStatus`** (Text, Automation: Read/Write). It records who has rights and until when, so you can see it from the device page. If the field doesn't exist, the script skips it.

**Revoke early:** run the same script with `action = Revoke`. When you run it manually, it removes every active grant right away.

## Logs and exit codes

- Log: `C:\ProgramData\TempLocalAdmin\TempLocalAdmin.log`. The NinjaOne activity output shows the same lines.
- State: `C:\ProgramData\TempLocalAdmin\grants.json`
- Exit `0` = success, `1` = failure, `2` = user was already an admin

## Limits to know

- **An admin is an admin.** During the window the user could, in theory, delete the task or add another account. Set up a NinjaOne condition or a daily script that alerts on any unexpected members of local Administrators.
- Programs that were started elevated keep running after the rights are revoked, until they exit.
- `msg.exe` notifications show up on Pro, Enterprise and Education editions.
- If a removal fails, the script retries every 5 minutes and reports exit 1 so NinjaOne flags it.

## Alternatives

- **Push the install from NinjaOne as SYSTEM** (Software/Third-party patching, or an install script). The user never gets admin rights, which makes this the best option for known apps.
- **Endpoint Privilege Management** (Intune EPM, or a NinjaOne privilege-management add-on if your license includes one) can elevate one approved app without making the user an admin. Check your licensing.
