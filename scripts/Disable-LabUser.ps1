#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Offboards an Active Directory user account.

.DESCRIPTION
    Performs a standard leaver process:
      1. Records current group membership in the account's description (audit trail)
      2. Removes the account from every security group except its primary group
      3. Resets the password to a random value so cached credentials stop working
      4. Disables the account
      5. Moves it to the Disabled OU

    The account is disabled rather than deleted. Deleting it destroys the SID,
    which breaks file ownership, mailbox permissions and audit-log resolution.
    Deletion is a separate decision made after a retention period.

.PARAMETER SamAccountName
    One or more accounts to offboard. Accepts pipeline input.

.EXAMPLE
    .\Disable-LabUser.ps1 -SamAccountName jsmith -WhatIf

.EXAMPLE
    .\Disable-LabUser.ps1 -SamAccountName jsmith, mpapadopoulos -Reason "Resigned 2026-09-30"

.EXAMPLE
    Get-Content .\leavers.txt | .\Disable-LabUser.ps1
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [string[]] $SamAccountName,

    [string] $Reason      = 'Offboarded',
    [string] $DomainDN    = (Get-ADDomain).DistinguishedName,
    [string] $RootOuName  = 'CORP'
)

begin {
    Import-Module ActiveDirectory -ErrorAction Stop

    $disabledOU = "OU=Disabled,OU=$RootOuName,$DomainDN"

    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$disabledOU'" -ErrorAction SilentlyContinue)) {
        throw "Disabled OU not found at '$disabledOU'. Run New-LabOUs.ps1 first."
    }

    function New-RandomPassword {
        param([int] $Length = 24)

        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789!@#$%^&*'
        $bytes = [byte[]]::new($Length)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)

        -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    }
}

process {

    foreach ($sam in $SamAccountName) {

        $user = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties MemberOf, Description, PrimaryGroup -ErrorAction SilentlyContinue

        if (-not $user) {
            Write-Warning "User not found: $sam"
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($user.DistinguishedName, 'Offboard account')) {
            continue
        }

        Write-Host "`nOffboarding $sam ($($user.Name))" -ForegroundColor Cyan

        # --- 1. Capture group membership before we destroy it -----------------
        $groupNames = $user.MemberOf | ForEach-Object { (Get-ADGroup $_).Name }

        $stamp = Get-Date -Format 'yyyy-MM-dd'
        $note  = if ($groupNames) {
            "$Reason $stamp | Removed from: $($groupNames -join ', ')"
        } else {
            "$Reason $stamp | No group memberships"
        }

        # Description has a practical length limit — truncate rather than fail
        if ($note.Length -gt 1024) { $note = $note.Substring(0, 1021) + '...' }

        Set-ADUser -Identity $user -Description $note
        Write-Host "  Recorded $($groupNames.Count) group membership(s) in description"

        # --- 2. Strip group memberships --------------------------------------
        # The primary group (normally Domain Users) cannot be removed while it
        # is set as primary, and MemberOf does not include it anyway.
        foreach ($dn in $user.MemberOf) {
            try {
                Remove-ADGroupMember -Identity $dn -Members $user -Confirm:$false -ErrorAction Stop
                Write-Host "  Removed from $((Get-ADGroup $dn).Name)"
            }
            catch {
                Write-Warning "  Could not remove from $($dn): $($_.Exception.Message)"
            }
        }

        # --- 3. Reset the password -------------------------------------------
        # Invalidates cached credentials and any active Kerberos ticket renewals.
        $newPassword = ConvertTo-SecureString (New-RandomPassword) -AsPlainText -Force
        Set-ADAccountPassword -Identity $user -Reset -NewPassword $newPassword
        Write-Host "  Password reset to a random value"

        # --- 4. Disable -------------------------------------------------------
        Disable-ADAccount -Identity $user
        Write-Host "  Account disabled"

        # --- 5. Move to the Disabled OU --------------------------------------
        # ProtectedFromAccidentalDeletion blocks moves as well as deletes,
        # so clear it, move, and leave it clear (the account is now inert).
        Set-ADObject -Identity $user.DistinguishedName -ProtectedFromAccidentalDeletion $false -ErrorAction SilentlyContinue
        Move-ADObject -Identity $user.DistinguishedName -TargetPath $disabledOU
        Write-Host "  Moved to $disabledOU" -ForegroundColor Green
    }
}

end {
    Write-Host "`nOffboarding complete.`n" -ForegroundColor Cyan
    Write-Host "Remaining manual steps in a real environment:" -ForegroundColor Yellow
    Write-Host "  - Convert the mailbox to shared, or set a forwarding rule"
    Write-Host "  - Archive the home directory, then revoke access"
    Write-Host "  - Reclaim licences (M365, VPN, SaaS)"
    Write-Host "  - Collect hardware and remove the device from MDM"
    Write-Host "  - Schedule deletion after the retention period`n"
}
