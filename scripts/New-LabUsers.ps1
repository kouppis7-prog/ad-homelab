#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Bulk-provisions Active Directory users from a CSV file.

.DESCRIPTION
    Reads a CSV of new starters and creates each one with:
      - a unique SamAccountName (first initial + surname, with collision handling)
      - correct OU placement based on the Department column
      - UPN, display name, job title, department
      - membership of the department's global security group
      - a home drive mapped to \\<FileServer>\Home$\<username>
      - a temporary password that must be changed at first logon

    Manager relationships are wired up in a second pass, so a manager can appear
    anywhere in the CSV relative to their reports.

    Safe to re-run: existing users are skipped rather than overwritten.

.PARAMETER CsvPath
    Path to the input CSV. Required columns: FirstName, LastName, Department, Title
    Optional column: Manager (the manager's full "FirstName LastName")

.EXAMPLE
    .\New-LabUsers.ps1 -CsvPath .\lab-users.csv -WhatIf

.EXAMPLE
    .\New-LabUsers.ps1 -CsvPath .\lab-users.csv -Verbose
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string] $CsvPath,

    [string] $DomainDN    = (Get-ADDomain).DistinguishedName,
    [string] $UpnSuffix   = (Get-ADDomain).DNSRoot,
    [string] $RootOuName  = 'CORP',
    [string] $FileServer  = 'DC01',
    [string] $HomeDrive   = 'H:',

    # Lab-only default. In production you would generate a random password per
    # user and deliver it out-of-band rather than sharing one across accounts.
    [string] $DefaultPassword = 'ChangeMe!2026#Lab'
)

Import-Module ActiveDirectory -ErrorAction Stop

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-UniqueSamAccountName {
    <#
        Builds a SamAccountName as first-initial + surname, lowercased and
        stripped of non-alphanumerics. If that is taken, appends a digit.
        Also honours names already queued in this run, so two new starters
        with the same generated name don't collide.
    #>
    param(
        [Parameter(Mandatory)] [string] $FirstName,
        [Parameter(Mandatory)] [string] $LastName,
        [string[]] $Reserved = @()
    )

    $base = ('{0}{1}' -f $FirstName.Substring(0, 1), $LastName).ToLower()
    $base = $base -replace '[^a-z0-9]', ''

    # SamAccountName has a 20-character limit
    if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }

    $candidate = $base
    $suffix    = 1

    while (
        ($Reserved -contains $candidate) -or
        (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue)
    ) {
        $suffix++
        $candidate = "$base$suffix"
    }

    return $candidate
}

function Get-DepartmentUserOU {
    param(
        [Parameter(Mandatory)] [string] $Department
    )
    return "OU=Users,OU=$Department,OU=Departments,OU=$RootOuName,$DomainDN"
}

# ---------------------------------------------------------------------------
# Load and validate input
# ---------------------------------------------------------------------------

$rows = Import-Csv -Path $CsvPath

$requiredColumns = @('FirstName', 'LastName', 'Department', 'Title')
$actualColumns   = $rows[0].PSObject.Properties.Name
$missing         = $requiredColumns | Where-Object { $_ -notin $actualColumns }

if ($missing) {
    throw "CSV is missing required column(s): $($missing -join ', ')"
}

Write-Host "`nLoaded $($rows.Count) row(s) from $CsvPath`n" -ForegroundColor Cyan

$securePassword = ConvertTo-SecureString $DefaultPassword -AsPlainText -Force

$created  = @()
$skipped  = @()
$failed   = @()
$reserved = @()

# ---------------------------------------------------------------------------
# Pass 1 — create the accounts
# ---------------------------------------------------------------------------

foreach ($row in $rows) {

    $firstName = $row.FirstName.Trim()
    $lastName  = $row.LastName.Trim()
    $dept      = $row.Department.Trim()
    $title     = $row.Title.Trim()

    $displayName = "$firstName $lastName"
    $targetOU    = Get-DepartmentUserOU -Department $dept

    # Fail loudly if the OU is missing rather than dumping users somewhere random
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetOU'" -ErrorAction SilentlyContinue)) {
        Write-Warning "No OU for department '$dept' ($displayName) — run New-LabOUs.ps1 first. Skipping."
        $failed += $displayName
        continue
    }

    # Already provisioned? Leave it alone.
    $existing = Get-ADUser -Filter "DisplayName -eq '$displayName'" -SearchBase "OU=$RootOuName,$DomainDN" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Verbose "Already exists, skipping: $displayName ($($existing.SamAccountName))"
        $skipped += $displayName
        continue
    }

    $sam = Get-UniqueSamAccountName -FirstName $firstName -LastName $lastName -Reserved $reserved
    $reserved += $sam

    $userParams = @{
        Name                  = $displayName
        GivenName             = $firstName
        Surname               = $lastName
        DisplayName           = $displayName
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@$UpnSuffix"
        Department            = $dept
        Title                 = $title
        Company               = 'Corp Lab Ltd'
        Path                  = $targetOU
        AccountPassword       = $securePassword
        Enabled               = $true
        ChangePasswordAtLogon = $true
        HomeDrive             = $HomeDrive
        HomeDirectory         = "\\$FileServer\Home$\$sam"
        ErrorAction           = 'Stop'
    }

    if ($PSCmdlet.ShouldProcess($displayName, "Create user '$sam' in $dept")) {
        try {
            New-ADUser @userParams

            # AGDLP: the account joins the department's Global group
            $globalGroup = "GG-$dept-Staff"
            if (Get-ADGroup -Filter "Name -eq '$globalGroup'" -ErrorAction SilentlyContinue) {
                Add-ADGroupMember -Identity $globalGroup -Members $sam -ErrorAction Stop
            }
            else {
                Write-Warning "Group '$globalGroup' not found — '$sam' created but not grouped."
            }

            Write-Host ("  {0,-22} {1,-10} {2}" -f $sam, $dept, $title) -ForegroundColor Green
            $created += $sam
        }
        catch {
            Write-Warning "Failed to create '$displayName': $($_.Exception.Message)"
            $failed += $displayName
        }
    }
}

# ---------------------------------------------------------------------------
# Pass 2 — set manager relationships
#
# Done separately because a manager may appear later in the CSV than their
# reports, and New-ADUser -Manager would fail if the object didn't exist yet.
# ---------------------------------------------------------------------------

if ($actualColumns -contains 'Manager') {

    Write-Host "`nSetting manager relationships..." -ForegroundColor Cyan

    foreach ($row in $rows) {

        if ([string]::IsNullOrWhiteSpace($row.Manager)) { continue }

        $displayName = "$($row.FirstName.Trim()) $($row.LastName.Trim())"
        $managerName = $row.Manager.Trim()

        $user    = Get-ADUser -Filter "DisplayName -eq '$displayName'" -ErrorAction SilentlyContinue
        $manager = Get-ADUser -Filter "DisplayName -eq '$managerName'" -ErrorAction SilentlyContinue

        if (-not $user)    { continue }
        if (-not $manager) {
            Write-Warning "Manager '$managerName' not found for '$displayName'."
            continue
        }

        if ($PSCmdlet.ShouldProcess($displayName, "Set manager to $managerName")) {
            Set-ADUser -Identity $user -Manager $manager
            Write-Verbose "$displayName -> reports to $managerName"
        }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host "`n--- Summary ---"                        -ForegroundColor Cyan
Write-Host "  Created: $($created.Count)"             -ForegroundColor Green
Write-Host "  Skipped: $($skipped.Count) (already existed)"
if ($failed.Count) {
    Write-Host "  Failed:  $($failed.Count)"          -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
}
Write-Host ""
