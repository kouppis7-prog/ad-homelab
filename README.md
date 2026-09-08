# Active Directory Home Lab — Windows Server 2022

A functional Active Directory environment built from scratch to practise core Windows systems administration: domain services, DNS, DHCP, Group Policy, file services with layered permissions, and scripted user lifecycle management.

Built in VirtualBox on an isolated network. All configuration is documented, and the user provisioning and offboarding processes are automated with PowerShell.

---

## Environment

| Role | Hostname | OS | Address |
|---|---|---|---|
| Domain Controller / DNS / DHCP / File Server | `DC01` | Windows Server 2022 (Desktop Experience) | 10.10.10.10 (static) |
| Workstation — IT | `WS-IT-01` | Windows 11 Enterprise | DHCP |
| Workstation — Finance | `WS-FIN-01` | Windows 11 Enterprise | DHCP |

**Forest / Domain:** `corp.lab` (NetBIOS `CORP`)
**Functional level:** Windows Server 2022
**Network:** `10.10.10.0/24`, isolated VirtualBox internal network — no route to the host LAN
**Directory size:** 20 users across 4 departments

## What's implemented

**Directory services**
- Single-forest, single-domain AD DS deployment with integrated DNS
- Departmental OU structure with Users / Computers / Groups separation
- Default `CN=Users` and `CN=Computers` containers redirected so no object escapes Group Policy scope

**Identity lifecycle**
- CSV-driven bulk provisioning: unique `SamAccountName` generation with collision handling, OU placement by department, group membership, home drive, forced password change at first logon, and manager relationships resolved in a second pass
- Offboarding script that records group membership to the account description, strips memberships, randomises the password, disables the account, and moves it to a `Disabled` OU

**Network services**
- DHCP scope `10.10.10.100–200` with DNS and domain-name options, authorised in AD

**Group Policy**
- Domain password and lockout policy
- Fine-grained password policy (PSO) applying stricter requirements to Domain Admins
- Security baseline: legal logon banner, last-username suppression, advanced audit policy
- Drive mappings via Group Policy Preferences with item-level targeting by security group
- Standard-user restrictions applied through security filtering so administrators are excluded

**File services**
- Departmental shares and per-user home directories
- Access control implemented with AGDLP group nesting; NTFS inheritance stripped and ACLs rebuilt explicitly

---

## Repository contents

```
├── docs/
│   ├── 01-design-decisions.md          Why the environment is structured this way
│   ├── 02-troubleshooting-dns.md       Hostname mismatch breaking name resolution
│   ├── 03-troubleshooting-lockout.md   Account lockout diagnosis
│   ├── 04-troubleshooting-trust.md     Secure channel failure and in-place repair
│   └── 05-limitations.md               What this lab does not do, and why it matters
├── scripts/
│   ├── New-LabOUs.ps1                  Builds the OU tree and departmental groups
│   ├── New-LabUsers.ps1                Bulk provisioning from CSV
│   ├── Disable-LabUser.ps1             Offboarding
│   └── lab-users.csv                   Sample source data
└── images/                             Screenshots and diagrams
```

## OU structure

```
corp.lab
└── OU=CORP
    ├── OU=Departments
    │   ├── OU=IT        → Users, Computers, Groups
    │   ├── OU=Finance   → Users, Computers, Groups
    │   ├── OU=HR        → Users, Computers, Groups
    │   └── OU=Sales     → Users, Computers, Groups
    ├── OU=Servers
    ├── OU=ServiceAccounts
    └── OU=Disabled
```

## Usage

```powershell
# On the domain controller, elevated
cd C:\Scripts

.\New-LabOUs.ps1 -WhatIf
.\New-LabOUs.ps1

.\New-LabUsers.ps1 -CsvPath .\lab-users.csv -WhatIf
.\New-LabUsers.ps1 -CsvPath .\lab-users.csv

# Offboarding
.\Disable-LabUser.ps1 -SamAccountName ageorgiou -Reason "Resigned 2026-09-30"
```

---

## Troubleshooting write-ups

Three failures were diagnosed and resolved during the build — one encountered genuinely, two introduced deliberately to practise recovery:

- **[DNS resolution failure from a hostname mismatch](docs/02-troubleshooting-dns.md)** — clients could reach the DC by IP but not by name
- **[Account lockout](docs/03-troubleshooting-lockout.md)** — locating the source using Event IDs 4740 and 4625
- **[Broken secure channel](docs/04-troubleshooting-trust.md)** — repairing the machine account password without rejoining the domain

---

## Known limitations

This is a lab, not a production design. See [docs/05-limitations.md](docs/05-limitations.md) for what is deliberately missing and what would be required in a real environment.
