#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Builds the OU structure and departmental global groups for the corp.lab AD environment.

.DESCRIPTION
    Creates a top-level container OU, a Departments tree with per-department
    Users / Computers / Groups sub-OUs, plus Servers, ServiceAccounts and Disabled OUs.
    Also creates one global security group per department (AGDLP "G" tier).

    Safe to re-run: existing objects are skipped, not recreated.

.EXAMPLE
    .\New-LabOUs.ps1 -WhatIf
    Shows what would be created without changing anything.

.EXAMPLE
    .\New-LabOUs.ps1
    Builds the structure.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $RootOuName   = 'CORP',
    [string[]] $Departments  = @('IT', 'Finance', 'HR', 'Sales'),
    [string]   $DomainDN     = (Get-ADDomain).DistinguishedName
)

Import-Module ActiveDirectory -ErrorAction Stop

function New-LabOU {
    <#  Creates an OU only if it does not already exist.  #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path
    )

    $dn = "OU=$Name,$Path"

    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Verbose "OU already exists, skipping: $dn"
        return $dn
    }

    if ($PSCmdlet.ShouldProcess($dn, 'Create OU')) {
        New-ADOrganizationalUnit -Name $Name `
                                 -Path $Path `
                                 -ProtectedFromAccidentalDeletion $true `
                                 -ErrorAction Stop
        Write-Host "  Created OU: $dn" -ForegroundColor Green
    }

    return $dn
}

function New-LabGroup {
    <#  Creates a security group only if it does not already exist.  #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('Global', 'DomainLocal', 'Universal')]
        [string] $Scope       = 'Global',
        [string] $Description = ''
    )

    if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-Verbose "Group already exists, skipping: $Name"
        return
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create $Scope group")) {
        New-ADGroup -Name          $Name `
                    -GroupScope    $Scope `
                    -GroupCategory Security `
                    -Path          $Path `
                    -Description   $Description `
                    -ErrorAction   Stop
        Write-Host "  Created group: $Name" -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------

Write-Host "`nBuilding OU structure in $DomainDN`n" -ForegroundColor Cyan

# Top-level container
$rootDN = New-LabOU -Name $RootOuName -Path $DomainDN

# Departments tree
$deptRootDN = New-LabOU -Name 'Departments' -Path $rootDN

foreach ($dept in $Departments) {

    $deptDN = New-LabOU -Name $dept -Path $deptRootDN

    # Users and Computers split so GPOs can be linked precisely —
    # Group Policy has separate User and Computer configuration halves.
    New-LabOU -Name 'Users'     -Path $deptDN | Out-Null
    New-LabOU -Name 'Computers' -Path $deptDN | Out-Null
    $groupsDN = New-LabOU -Name 'Groups' -Path $deptDN

    # AGDLP: accounts go into a Global group.
    New-LabGroup -Name        "GG-$dept-Staff" `
                 -Path        $groupsDN `
                 -Scope       Global `
                 -Description "All staff in the $dept department"
}

# Peer OUs
New-LabOU -Name 'Servers'         -Path $rootDN | Out-Null
New-LabOU -Name 'ServiceAccounts' -Path $rootDN | Out-Null
New-LabOU -Name 'Disabled'        -Path $rootDN | Out-Null

# ---------------------------------------------------------------------------
# Redirect the default containers.
#
# CN=Users and CN=Computers are containers, not OUs, so no GPO can be linked
# to them. Anything created without an explicit -Path lands there and escapes
# policy entirely. Redirecting them closes that gap.
# ---------------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess('Default containers', 'Redirect to IT OU')) {
    $itUsersDN = "OU=Users,OU=IT,OU=Departments,OU=$RootOuName,$DomainDN"
    $itCompsDN = "OU=Computers,OU=IT,OU=Departments,OU=$RootOuName,$DomainDN"

    & redirusr $itUsersDN
    & redircmp $itCompsDN
    Write-Host "  Redirected default user/computer containers" -ForegroundColor Green
}

Write-Host "`nDone.`n" -ForegroundColor Cyan

Get-ADOrganizationalUnit -Filter * -SearchBase $rootDN |
    Select-Object -ExpandProperty DistinguishedName |
    Sort-Object
