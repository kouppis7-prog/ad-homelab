# Troubleshooting: Account Lockout

**Scenario type:** deliberately induced to practise diagnosis
**Relevant Event IDs:** 4740 (account locked out), 4625 (failed logon), 4776 (credential validation)

> Replace the sample output below with your own once you have run the scenario. Keep the structure.

---

## Symptom

A user reports being unable to log in, with the message *"The referenced account is currently locked out and may not be logged on to."* The password is correct and has not recently changed.

---

## Prerequisites

Lockout only occurs if a threshold is configured. This environment sets it in the Default Domain Policy:

- Account lockout threshold: 5 invalid attempts
- Account lockout duration: 15 minutes
- Reset counter after: 15 minutes

Audit logging must also be enabled for the relevant events to be recorded — see the security baseline GPO, which enables **Audit User Account Management** and **Audit Logon** for both success and failure.

---

## Diagnosis

Confirm the lockout rather than taking the report at face value:

```powershell
PS> Search-ADAccount -LockedOut | Select-Object Name, SamAccountName, LastLogonDate
```

```
<paste your output>
```

Identify where the failed attempts originated. Event 4740 is written on the domain controller that processed the lockout, and its `Caller Computer Name` field records the source machine:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4740} -MaxEvents 5 |
    Format-List TimeCreated, Message
```

```
<paste your output — note the Caller Computer Name>
```

Examine the failed logons themselves. The status and sub-status codes distinguish a wrong password from a disabled account or an expired one:

```powershell
Get-WinEvent -FilterHashtable @{LogName='Security'; ID=4625} -MaxEvents 10 |
    Select-Object TimeCreated, @{n='User';e={$_.Properties[5].Value}}
```

```
<paste your output>
```

---

## Resolution

```powershell
Unlock-ADAccount -Identity smichael
```

Confirm:

```powershell
Get-ADUser smichael -Properties LockedOut | Select-Object Name, LockedOut
```

---

## Analysis

Unlocking the account resolves the symptom but not the cause. If the source of the bad credentials is still running, the account will lock again within minutes.

In production the common causes, roughly in order of frequency:

- A mobile device with a cached mail password that was changed elsewhere
- A mapped drive or scheduled task running under stale credentials
- A service configured with a user account whose password has since rotated
- An active RDP or console session left signed in on another machine after a password change
- Less often, a password-spraying attempt against the directory

The `Caller Computer Name` in event 4740 is what separates these. A lockout sourced from the user's own workstation suggests a cached credential; one sourced from a server suggests a service or scheduled task; one with no consistent source, or sourced from many machines, warrants a closer look.

Repeated lockouts across multiple accounts from a single source is a different problem entirely and should be treated as a security incident rather than a support ticket.
