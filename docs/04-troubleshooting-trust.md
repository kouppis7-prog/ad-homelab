# Troubleshooting: Broken Secure Channel ("Trust Relationship Failed")

**Scenario type:** deliberately induced to practise recovery
**Error:** *The trust relationship between this workstation and the primary domain failed.*

> Replace the sample output below with your own once you have run the scenario. Keep the structure.

---

## Background

Every domain-joined computer holds an account in Active Directory with its own password, set at join time and rotated automatically every 30 days by default. That password establishes the *secure channel* — the authenticated connection between the workstation and a domain controller that all domain authentication depends on.

If the password held by the workstation and the one stored in AD diverge, the secure channel cannot be established and domain logons fail, even though the network, DNS and the user's own credentials are all fine.

---

## Inducing the failure

On the domain controller, in Active Directory Users and Computers (`dsa.msc`), locate the computer object and select **Reset Account**. This sets the machine password on the directory side only; the workstation is unaware and continues to present the old one.

---

## Symptom

Domain logon fails at the sign-in screen with the trust relationship error. Notably:

- The machine is on the network and can reach the domain controller
- DNS resolves correctly
- The user's credentials are valid and the account is not locked
- Local accounts still work

That last point is what makes recovery possible, and is the practical argument for maintaining a local administrator account on every machine.

---

## Diagnosis

Signed in with a **local** administrator account:

```powershell
PS> Test-ComputerSecureChannel -Verbose
False
```

```
<paste your output>
```

A `False` result confirms the secure channel specifically, rather than a network, DNS or credential problem. Worth running the adjacent checks to demonstrate those layers are healthy:

```powershell
Test-NetConnection DC01.corp.lab -Port 445
Resolve-DnsName DC01.corp.lab
nltest /dsgetdc:corp.lab
```

---

## Resolution

```powershell
Test-ComputerSecureChannel -Repair -Credential (Get-Credential CORP\Administrator)
```

Verify:

```powershell
PS> Test-ComputerSecureChannel
True
```

Reboot, and domain logon succeeds.

---

## Why repair rather than rejoin

The instinctive fix is to remove the machine from the domain and rejoin it. That works, but it is disproportionate:

- It can create a new computer object, or leave an orphaned one behind
- The object's group memberships and any directly linked policy scope are lost
- The machine may land back in the default container rather than its correct OU
- It requires two reboots and, on a real workstation, risks the user profile being recreated

`Test-ComputerSecureChannel -Repair` resets the machine account password on both sides in place. The computer object, its OU placement, its group memberships and its SID are all preserved. `Reset-ComputerMachinePassword` achieves the same result.

---

## Real-world causes

**Virtual machine snapshot rollbacks** are the dominant cause and the reason this failure is far more common in labs and test environments than on physical desktops. Restoring a VM to a snapshot taken before the last machine password rotation leaves it holding a password the directory has already replaced.

Others worth knowing:

- A machine offline for longer than the tombstone period, then reconnected
- Restoring a workstation from an old image or backup
- Two machines sharing a hostname, each overwriting the other's account password
- Clock skew beyond the Kerberos tolerance (five minutes by default), which produces different errors but is often confused with this one

Given how much of this lab was built across VM snapshots, this is a failure mode I would expect to encounter without inducing it deliberately.
