# Troubleshooting: Name Resolution Failure Caused by a Hostname Mismatch

**Encountered during:** file services configuration
**Impact:** home drives failed to map; all UNC paths referencing the server by name failed
**Root cause:** the domain controller's hostname did not match the name used throughout the configuration

---

## Symptom

After configuring departmental shares and per-user home directories, no client could map its home drive. Testing the path directly from a domain-joined workstation:

```powershell
PS> Test-Path '\\DC01\Home$\ageorgiou'
False
```

The share had been created successfully on the server, and the folder existed locally. Nothing in the share configuration appeared wrong.

---

## Diagnosis

The first useful step was establishing whether this was a permissions problem or a connectivity problem. Testing a share that exists on every domain controller:

```powershell
PS> Test-Path '\\DC01\SYSVOL'
False
```

A built-in share also failing pointed away from my configuration and toward the connection itself.

Testing connectivity by address versus by name separated the two:

```powershell
PS> ping 10.10.10.10
Reply from 10.10.10.10: bytes=32 time<1ms TTL=128

PS> ping DC01
Ping request could not find host DC01.
```

The host was reachable. The name was not resolving.

The next question was whether DNS was failing or answering incorrectly. Querying the domain controller directly:

```powershell
PS> Resolve-DnsName DC01.corp.lab -Server 10.10.10.10
Resolve-DnsName : DC01.corp.lab : DNS name does not exist
```

**This response was the key to the diagnosis.** A DNS server that is down, unreachable, or blocked by a firewall produces a timeout. An authoritative *"does not exist"* means the service is healthy, the zone is loaded, and the server is confident there is no such record. The problem was not DNS — the record genuinely did not exist.

Enumerating what the zone actually contained:

```powershell
PS> Get-DnsServerResourceRecord -ZoneName corp.lab -RRType A | Select-Object HostName, RecordData
```

The A record was registered against `DS01`, not `DC01`.

```powershell
PS> hostname
DS01
```

The server had been named `DS01` during the initial configuration — a typo at the rename step. Active Directory, DNS and the SMB server were all working exactly as designed and registering the machine's real name. Every reference I had written since pointed at a host that did not exist.

---

## Resolution

Renaming a domain controller is not a straightforward `Rename-Computer` operation, because the name is embedded in the machine's service principal names and its DNS registrations. `netdom` handles the transition properly by adding the new name, promoting it to primary, and allowing the old one to be removed once replication has settled.

```powershell
netdom computername DS01.corp.lab /add:DC01.corp.lab
netdom computername DS01.corp.lab /makeprimary:DC01.corp.lab
Restart-Computer
```

After the reboot, the redundant name was removed:

```powershell
netdom computername DC01.corp.lab /remove:DS01.corp.lab
```

Verification:

```powershell
PS> hostname
DC01

PS> Get-ADDomainController | Select-Object Name, HostName
PS> dcdiag /q
```

`dcdiag /q` reports only failures — no output means a clean result.

The user objects still carried home directory paths pointing at the old name, so those were corrected:

```powershell
Get-ADUser -Filter * -SearchBase "OU=CORP,DC=corp,DC=lab" | ForEach-Object {
    $target = '\\DC01\Home$\' + $_.SamAccountName
    Set-ADUser $_ -HomeDrive "H:" -HomeDirectory $target
}
```

Clients required `ipconfig /flushdns` to clear the cached negative response before the name resolved.

---

## What I took from this

**The specific DNS error message was more informative than the fact of the failure.** "Does not exist" and "request timed out" look equally like failure at a glance but point in opposite directions — one at a missing record, the other at a service or network problem. Reading the distinction saved me from investigating the DNS service, which was working correctly throughout.

**Testing a known-good reference isolates the variable.** Checking `SYSVOL` — a share I had not created and could not have misconfigured — established within seconds that the problem was not in my file server configuration. Without that, I would have spent considerably longer re-checking share permissions.

**Working outward from the lowest layer is faster than guessing.** ICMP by address, then by name, then DNS resolution, then the record itself. Each step eliminated a layer, and the failure appeared exactly where the tests stopped agreeing with each other.

**A trivial error can produce symptoms far from its cause.** A two-character typo in a hostname surfaced as a file-sharing failure several configuration steps later. Verifying the basics — hostname, IP, DNS registration — immediately after a rename would have caught it before anything was built on top.
