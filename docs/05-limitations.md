# Limitations

What this environment deliberately does not implement, and what a production deployment would require instead. Listing these is part of the exercise — knowing where a design stops being adequate matters as much as building it.

---

## Availability

**Single domain controller.** There is no redundancy. If `DC01` fails, authentication, DNS and DHCP all stop, and the directory is unrecoverable without a restore.

Production requires a minimum of two domain controllers per site, with FSMO roles distributed and a documented seizure procedure for the loss of a role holder. Sizing beyond that is driven by user count, site topology and link reliability.

**No tested backup or restore.** Windows Server Backup can capture system state, which includes the AD database, SYSVOL and the registry — but a backup that has never been restored is an assumption, not a control.

A real environment needs scheduled system state backups, offsite retention, and periodic restore testing. It also needs the distinction between authoritative and non-authoritative restore to be understood *before* it is needed, along with a rehearsed forest recovery plan.

---

## Role separation

**Everything runs on the domain controller** — DNS, DHCP, and file services.

DNS on a DC is normal and expected. DHCP is common in small environments and acceptable. File services on a domain controller is not: it puts user data on the most security-sensitive machine in the environment, requires ordinary users to have read access to a DC's filesystem, and turns a file server capacity problem into a directory availability problem.

A member server would be correct. This lab consolidates for resource reasons.

**No dedicated management workstation.** Administration was performed while signed in to the domain controller itself. Correct practice is RSAT on a hardened administrative workstation, with the DC console reserved for genuine break-glass situations.

---

## Security

**No tiered administration model.** A single `Domain Admins` account was used throughout. Microsoft's tiering model separates directory administration (Tier 0), server administration (Tier 1) and workstation support (Tier 2), with credentials from a higher tier never exposed on a lower-tier machine. This is the single most valuable structural control against credential theft in a Windows estate, and it is absent here.

**No LAPS.** Local administrator passwords on the workstations are unmanaged. Windows LAPS randomises them per machine and stores them in the directory, removing the shared-local-password problem that makes lateral movement trivial.

**No PKI.** There is no certificate authority, so no LDAPS, no certificate-based authentication, and no signed internal services. AD CS would be the next significant addition.

**Credential exposure in provisioning.** `New-LabUsers.ps1` accepts a single default password as a parameter, applied to every account with a forced change at first logon. This is a lab convenience. Production provisioning should generate a unique random password per account and deliver it out of band, or avoid an initial password entirely by using a temporary access pass or a self-service enrolment flow.

**Group Policy is not a security boundary.** The standard-user restrictions — blocked Control Panel, command prompt, registry editor — raise the effort required and prevent accidental changes. They do not stop a determined user, and should not be mistaken for application control. AppLocker or Windows Defender Application Control would be the real mechanism.

**No monitoring.** Audit logging is enabled and events are being written, but nothing collects, correlates or alerts on them. Logs sitting on the machine that generated them are of limited value during an incident and can be cleared by an attacker who reaches the box. Forwarding to a collector or SIEM would be the next step.

---

## Network

**Flat, unsegmented network.** All hosts share `10.10.10.0/24` with no VLANs, no firewall between segments, and no restriction on which machines may reach the domain controller's management interfaces.

A production design would separate server and client networks, restrict administrative protocols to a management VLAN, and apply host-based firewall rules rather than relying on the perimeter.

**No internet access by design.** The lab uses a VirtualBox internal network, which keeps it isolated from the host LAN. This is a deliberate safety property rather than a limitation, but it does mean patch management is untested — and patching is a substantial part of the real work of running a Windows estate.

---

## Identity lifecycle

**Provisioning is manually triggered.** The scripts run on demand against a CSV. A real environment drives joiner-mover-leaver processes from an authoritative source — an HR system or an IAM platform — with approval workflow, audit trail and automated deprovisioning on termination.

**Offboarding is incomplete.** `Disable-LabUser.ps1` handles the directory side: group removal, password randomisation, account disable, and relocation to a `Disabled` OU. It does not address mailbox conversion, home directory archival, licence reclamation, MDM device removal, or the scheduled deletion that should follow the retention period. Those steps are listed in the script's output as a reminder rather than automated.

**No group lifecycle management.** Security groups are created once and never reviewed. Access accumulates. Periodic access recertification is what prevents that, and there is none here.

**No service account management.** The `ServiceAccounts` OU exists but is empty. Real environments should be using group Managed Service Accounts where the application supports them, which removes manual password rotation entirely.

---

## Scale

The environment holds 20 users and 2 workstations. Several decisions that are reasonable here would not survive growth:

- A single OU tier per department works at four departments; a multi-site or multi-region organisation needs geography factored into the structure
- One GPO containing all drive mappings is maintainable at four departments and would not be at forty
- Item-level targeting evaluated per user at logon is inexpensive at this size and becomes a measurable logon delay when overused
- Manual OU placement of computer objects at join time does not scale; production uses a provisioning process or dynamic assignment
