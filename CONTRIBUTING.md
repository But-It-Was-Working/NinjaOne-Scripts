# Contributing

Thanks for helping. A few rules keep the scripts here safe to run on other people's devices.

## Adding a script

1. Copy `Templates/Script-Template.ps1` to `Scripts/<Category>/<Verb-Noun>/<Verb-Noun>.ps1`. Use an [approved PowerShell verb](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).
2. Copy `Templates/Script-README-Template.md` next to it as `README.md` and fill in every section.
3. Add a row to the **Scripts** table in the main `README.md`.
4. Open a pull request. CI runs PSScriptAnalyzer and must pass with no errors.

## Requirements

- **No secrets or internal details.** No API keys, passwords, tenant or org IDs, internal hostnames, UNC paths, or company names. Take these as script variables instead.
- **Non-interactive.** The script must finish without anyone at the keyboard.
- **Safe by default.** Destructive actions need an explicit variable to turn them on, and the script should check before it changes anything.
- **Clear exit codes.** `0` = success. Document every other code in the README.
- **Tested.** Say in the PR which Windows versions and NinjaOne "Run As" contexts you tested with.

## Reporting a problem

Open an issue with the script name, Windows version, the "Run As" context, the script variables you used (with anything sensitive removed), and the NinjaOne activity output.

Don't post real customer data, hostnames or credentials in issues.
