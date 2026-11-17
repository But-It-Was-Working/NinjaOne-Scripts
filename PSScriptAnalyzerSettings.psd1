@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # RMM scripts run unattended, so -WhatIf / -Confirm support has no one to serve.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
