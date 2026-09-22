# Windows 11 Install Plan - Independent Analysis

> **⚠️ HISTORICAL (2026-04-23).** Review of an earlier state. Many findings here
> (scripts 04–06 and `pxe/boot.ipxe` "missing", autounattend issues) are resolved;
> those scripts now exist and the answer file is reworked. See `README.md` for the
> current state. Kept for history.

**Date:** 2026-04-23  
**Author:** Orchestrator Analysis  
**Status:** Critical Issues Found

---

## Executive Summary

The plan has a **sound technical foundation** but suffers from **severe incompleteness**. Only 4 of 7 planned scripts exist. Several critical files referenced in PLAN.md are missing. The autounattend.xml has configuration errors that will cause setup to fail.

**Recommendation:** DO NOT attempt to run this plan until all identified issues are resolved.

---

## Gap Analysis: What's Missing

| Planned File | Status | Priority |
|--------------|--------|----------|
| `scripts/04-setup-http.sh` | **MISSING** | Critical |
| `scripts/05-create-vm.sh` | **MISSING** | Critical |
| `scripts/06-boot-vm.sh` | **MISSING** | Critical |
| `pxe/boot.ipxe` | **MISSING** | Critical |
| `http/winpe/wimboot` symlink | Unreliable | High |
| config.sh validation function | Broken | High |

---

## Critical Issues

### 1. autounattend.xml Has Wrong Image Path

Line 47 in autounattend.xml:
```xml
<Path> install.wim</Path>
```

**Problem:** This references `install.wim` (the Windows installation image) but we're booting from `boot.wim`. The `ImageInstall` section is **ignored during WinPE phase** - it's only used when Windows Setup actually runs from the full install.wim.

**Impact:** Disk partitioning will NOT happen automatically. Windows will use the entire disk or prompt (depending on Windows 11 version).

**Fix:** Either:
- Remove the `ImageInstall` section (disk auto-partitions anyway with `WillWipeDisk=true`)
- OR inject a separate autounattend.xml into install.wim later

### 2. autounattend.xml References Non-Existent Edition

Line 50:
```xml
<Value>Windows 11 Pro</Value>
```

**Problem:** The edition name varies by ISO. "Windows 11 Pro" might be "Windows 11 专业版" or "Windows 11 Pro N" depending on ISO source.

**Impact:** If the exact string doesn't match, the answer file fails silently and setup prompts for edition selection.

**Fix:** Use a wildcard or detect the actual edition from the ISO before running.

### 3. autounattend.xml AutoLogon is Dangerous

Lines 65-72 enable AutoLogon for Administrator with no password:
```xml
<AutoLogon>
    <Password><Value></Value></Password>
    <Enabled>true</Enabled>
    <LogonCount>9999999</LogonCount>
    <Username>Administrator</Username>
</AutoLogon>
```

**Problem:** During WinPE phase, there's no "Administrator" account yet. The AutoLogon component in oobeSystem pass runs AFTER Windows is installed, not during WinPE.

**Impact:** This section is silently ignored during WinPE boot. It's meant for the installed Windows, not the PE environment.

### 4. QEMU TFTP Path Not Documented

The boot.ipxe is missing, but even in PLAN.md, the QEMU invocation shows:
```bash
-netdev user,id=net0,tftp=pxe,bootfile=boot.ipxe
```

**Problem:** The `tftp=pxe` is a relative path. It must resolve to an absolute path or be relative to QEMU's working directory. The scripts don't ensure proper CD.

**Impact:** iPXE boot fails silently or loads wrong file.

---

## Script Issues by File

### config.sh - Multiple Problems

**Issue 1:** The validation function returns errors incorrectly:
```bash
return $errors
```
bash `return` only works for exit codes 0-255. If errors > 255, it wraps incorrectly.

**Issue 2:** Uses `-f` to check ISO but doesn't verify it's actually an ISO:
```bash
[[ -f "$ISO_PATH" ]]
```

Should also check:
```bash
file "$ISO_PATH" | grep -q "ISO" || ...
```

**Issue 3:** No port conflict detection:
```bash
HTTP_PORT="8080"
```

Should check:
```bash
netstat -tuln 2>/dev/null | grep -q ":$HTTP_PORT " && ...
```

### 01-install-deps.sh - Port Conflict Not Handled

The script installs nginx but doesn't check if it's already running on port 8080, or configure nginx to use the right port.

### 02-extract-winpe.sh - Good Basic Structure

This script is reasonably solid but:
- Hardcodes the mount point `/mnt/winiso` which could conflict
- Uses `trap cleanup EXIT` which runs even on success - minor issue

### 03-inject-autounattend.sh - Verification Doesn't Work

Line 22-31 tries to verify injection but the grep pattern won't work:
```bash
wimlib-imagex info "http/winpe/boot.wim" 1 | grep -q "autounattend.xml"
```

The `wimlib-imagex info` doesn't list individual files that way. Should use:
```bash
wimlib-imagex extract "http/winpe/boot.wim" 1 /autounattend.xml - 2>/dev/null | head -1
```

Or just skip verification and trust it worked.

### 00-bootstrap.sh - OK but Incomplete

Basic structure is fine. Creates directories and config.sh template.

---

## TPM and BitLocker Risk

**Critical for re-runs:** If someone deletes the .qcow2 disk but keeps the swtpm state directory, Windows will detect "TPM state changed" and require BitLocker recovery on an encrypted disk.

**No script handles this.** The plan references swtpm but scripts 05 and 06 don't exist to manage it.

---

## What Works

1. **Boot chain concept** - iPXE → wimboot → WinPE is correct
2. **Using boot.wim from ISO** - Avoids needing Windows ADK
3. **QEMU user-mode networking** - 10.0.2.2 gateway is correct
4. **Dependency installation** - wimtools + nginx + wimboot is the right stack
5. **File extraction** - Correct source paths from ISO

---

## Required Fixes (Priority Order)

### P0 - Must Fix Before Any Run

1. Create `scripts/04-setup-http.sh` - nginx config and startup
2. Create `scripts/05-create-vm.sh` - disk + TPM state creation with proper cleanup
3. Create `scripts/06-boot-vm.sh` - QEMU launch with absolute paths
4. Create `pxe/boot.ipxe` - iPXE script with correct HTTP URLs

### P1 - Must Fix Before Automating

5. Fix autounattend.xml - Remove invalid ImageInstall section or make edition detection dynamic
6. Fix config.sh validation function
7. Add port conflict detection before nginx starts

### P2 - Should Fix for Robustness

8. Add RPM/state cleanup on disk recreation
9. Verify wimboot download checksum
10. Add timeout handling for network operations

---

## autounattend.xml - Simplified Recommended Version

For WinPE-only boot (install.wim attached as CDROM), use:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupLocale>en-US</SetupLocale>
            <UserLocale>en-US</UserLocale>
            <UILanguage>en-US</UILanguage>
            <SystemLocale>en-US</SystemLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DiskConfiguration>
                <Disk wcm:action="add">
                    <DiskID>0</DiskID>
                    <WillWipeDisk>true</WillWipeDisk>
                </Disk>
            </DiskConfiguration>
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
</unattend>
```

This lets Windows auto-partition and accept EULA. The rest happens interactively or from autounattend in install.wim.

---

## Conclusion

The plan is **not ready for execution**. The critical missing scripts (04-06) and boot.ipxe must be created. The autounattend.xml has configuration errors.

**Estimated work to fix:**
- 4 new scripts (04-06 + missing one)
- 1 new pxe/boot.ipxe
- 1 autounattend.xml fix
- 1 config.sh fix

Total: ~300 lines of new code minimum.