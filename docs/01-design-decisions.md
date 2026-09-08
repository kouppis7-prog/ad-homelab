# Design Decisions

The reasoning behind how this environment is structured. Most of these choices have a defensible alternative; what follows is why I went the way I did.

---

## Domain naming: `corp.lab`

`.local` is the obvious choice and a poor one — it collides with multicast DNS (Bonjour/Avahi), which causes intermittent resolution failures on mixed networks that are genuinely unpleasant to diagnose.

Correct practice in production is a subdomain of a publicly registered domain the organisation controls, such as `ad.company.com`. That keeps the namespace unambiguous and leaves the option open for split-brain DNS or federation later.

`corp.lab` is a lab compromise: short, unambiguous, and not `.local`.

---

## A single top-level `CORP` OU

Everything sits under one container OU rather than directly beneath the domain root.

This makes GPO scoping predictable. Policies can be linked at `OU=CORP` and inherited downward without touching the domain root, where the Default Domain Policy lives and where changes have forest-wide consequences. It also means inheritance can be blocked cleanly at a single point if a subtree ever needs isolation.

## Users and Computers split within each department

Group Policy has two independent halves — Computer Configuration and User Configuration — and each is evaluated against the object's own position in the directory. Keeping users and computers in separate OUs means a policy can be linked exactly where it applies.

The alternative is putting both object types in one OU and using loopback processing to force user settings to follow the machine. Loopback has legitimate uses (kiosks, shared terminals, RDS hosts) but it makes policy resolution harder to reason about, and reaching for it as a default is a sign the OU structure is wrong.

## Redirecting the default containers

`CN=Users` and `CN=Computers` are containers, not organisational units, and no GPO can be linked to them. Any object created without an explicit path lands there and receives only domain-level policy.

`redirusr` and `redircmp` change the default destination to a real OU, closing that gap. It is two commands and it eliminates an entire category of "why isn't this policy applying" problems.

## A dedicated `Disabled` OU

Leavers are disabled and moved, not deleted.

Deleting an account destroys its SID, which breaks file ownership, ACL entries that reference it, and the resolution of historical audit log entries. Deletion is a separate decision made after a retention period, not part of the offboarding process itself.

---

## Password policy: domain-wide plus a PSO

Account and password policy is domain-wide by design and can only be set at the domain root — this is the one legitimate reason to edit the Default Domain Policy.

Privileged accounts need stricter requirements than that single policy allows, so Domain Admins get a Fine-Grained Password Policy with a longer minimum length, shorter maximum age, and a lower lockout threshold. FGPPs are applied to groups and take precedence over the domain policy by their `Precedence` value.

## Security filtering rather than more OUs

The standard-user restriction GPO is linked broadly at `OU=Departments`, then filtered so it applies only to departmental staff groups and not to IT.

The alternative — a separate OU for administrators — works, but it couples policy scope to directory structure. Filtering by group membership means an administrator can be moved between departments without falling out of scope of the right policies.

## Drive mappings: one GPO, item-level targeting

Rather than four department-specific GPOs, one `CORP-Drive-Maps` policy contains four mappings, each targeted at the relevant global group.

Item-level targeting evaluates per preference item, so a single policy produces different results for different users. Fewer objects to maintain, and the mapping logic sits in one place.

## Home drives moved from the AD attribute to Group Policy Preferences

Home directories were initially set through the `HomeDrive` and `HomeDirectory` attributes on each user object. This is the legacy mechanism and it has two problems.

First, setting the attributes via PowerShell does not create the underlying folder. Active Directory Users and Computers creates it as a side effect when the home folder is set through its GUI, but `New-ADUser` and `Set-ADUser` only write the attribute value. The client then attempts to map a drive to a path that does not exist and silently gives up.

Second, the attribute-based mapping proved unreliable on Windows 11 even once the folders existed.

The environment now maps home drives through Group Policy Preferences using `\\DC01\Home$\%LogonUser%`, running in the logged-on user's security context. This is Microsoft's current guidance, it fails visibly rather than silently, and it keeps the mapping logic alongside the other drive maps rather than scattered across user objects.

---

## File permissions: AGDLP

Accounts → **G**lobal groups → **D**omain **L**ocal groups → **P**ermissions.

Granting the departmental global group direct access to a folder would work. Separating the tiers means organisational membership and resource access change independently:

- `GG-Finance-Staff` answers *who works in Finance* — an HR question
- `DL-Finance-Modify` answers *who can write to this folder* — a resource question

Granting Sales read access to a Finance folder becomes one group nesting change rather than an ACL edit on the filesystem. The ACL is written once and never touched again.

The model also matters across domain boundaries: global groups can only contain principals from their own domain, while domain local groups accept members from anywhere in the forest.

## Share permissions permissive, NTFS restrictive

Share permissions and NTFS permissions are evaluated together, and the more restrictive of the two wins for network access. Share permissions are coarse, have no inheritance, and apply only over SMB.

All meaningful access control is therefore implemented in NTFS, with share permissions left at Change for Authenticated Users. One place to look, one place to change, and identical behaviour whether a user reaches the data over the network or from the console.

NTFS inheritance is stripped (`icacls /inheritance:r`) before ACLs are applied, because folders under `C:\` inherit read access for `BUILTIN\Users` by default — which would grant every domain user read access to departmental data regardless of the group design above it.

---

## Provisioning: two passes

`New-LabUsers.ps1` creates all accounts first, then resolves manager relationships in a second pass.

`New-ADUser -Manager` requires the manager object to already exist. Managers can appear anywhere in the source CSV relative to their reports, and sorting the input to guarantee ordering fails as soon as the hierarchy is more than two levels deep. Two passes removes the constraint entirely.

## Execution policy: `RemoteSigned`

Set at `CurrentUser` scope rather than machine-wide, and `RemoteSigned` rather than `Bypass` or `Unrestricted`. Locally authored scripts run; anything carrying a mark-of-the-web must be signed or explicitly unblocked.

`Bypass` would have been faster and would have removed a legitimate safety control for no good reason.
