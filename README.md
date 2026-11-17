# NinjaOne Scripts

Free, community PowerShell scripts for the [NinjaOne](https://www.ninjaone.com/) RMM. Each script is written to run from NinjaOne's **Automation Library**, uses NinjaOne **script variables** for its inputs, and documents its setup in its own README.

> These scripts are provided as-is under the [MIT License](LICENSE). Read every script and test it on a non-production device before you deploy it. Nothing here is affiliated with or endorsed by NinjaOne.

## Scripts

| Script | Category | What it does |
|---|---|---|
| [Invoke-TempLocalAdmin](Scripts/Security/Invoke-TempLocalAdmin) | Security | Grants a user local admin for 5, 15 or 30 minutes, then revokes it automatically. |

## Using a script in NinjaOne

1. Open the script's folder and read its README.
2. In NinjaOne go to **Administration → Library → Automation → Add → New Script**.
3. Set **Language** to PowerShell, then set **Operating System** and **Run As** to what the README says.
4. Paste in the `.ps1` contents.
5. Add the **script variables** listed in the README, using the exact names given. NinjaOne passes them to the script as environment variables.
6. Run it against one test device and check the activity output before rolling it out.

## Repo layout

```
Scripts/
  <Category>/
    <Verb-Noun>/
      <Verb-Noun>.ps1     the script
      README.md           setup, variables, exit codes, limits
Templates/
  Script-Template.ps1     starting point for new scripts
  Script-README-Template.md
```

Categories: `Security`, `Software`, `Maintenance`, `Monitoring`, `Networking`, `UserManagement`. Add a new one when none of these fit.

## Conventions

Every script in this repo:

- Runs non-interactively. No prompts, no `Read-Host`, no GUI.
- Accepts NinjaOne script variables (`$env:<name>`) and also normal `-Parameters`, so it can be tested from a console.
- Writes progress with `Write-Output`, which NinjaOne captures in the activity log.
- Exits with `0` for success and a non-zero code for failure, and documents what each code means.
- Contains no secrets, hostnames, tenant IDs or company-specific paths.
- Passes PSScriptAnalyzer in CI with no errors.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
