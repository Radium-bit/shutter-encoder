# Tracking Upstream Updates

This repository maintains a prompt-free build on top of [paulpacifico/shutter-encoder](https://github.com/paulpacifico/shutter-encoder): upstream features and fixes are preserved, while the donation popup, the startup update check, and device fingerprint collection are removed.

Branch layout:

| Branch | Purpose |
| --- | --- |
| `master` | Upstream mirror. Fast-forward only, never commit here |
| `no-prompt` | Delivery branch carrying all patches for this project |

Never commit anything on `master`. Its only legitimate update is `git merge --ff-only origin/master`. Once a local commit lands on `master`, rebasing `no-prompt` drags that commit along and the mirror stops matching the official tree, which defeats the purpose of having a clean reference.

---

## 1. Patch Inventory

Changes fall into three categories. Handle each category the same way on every upgrade.

### 1.1 Files added by us (upstream never touches them)

| File | Purpose |
| --- | --- |
| `build-noPrompt.ps1` | Compile, build fat jar, generate jpackage image, run NSIS packaging |
| `installer/ShutterEncoder.nsi` | Install and uninstall script, 64-bit registry entries and shortcuts |
| `audit-noPrompt.ps1` | Scans for reintroduced popups, update checks, and telemetry |
| `.gitattributes` | Protects the UTF-8 BOM and line endings of `.ps1` and `.nsi` files |
| `.gitignore` | Ignores `Library`, `LUTs`, `build`, and other runtime artifacts |
| `Start-ShutterEncoder.ps1`, `run.bat` | Local launchers for running from source |

If upstream adds a file with the same name, inspect its purpose before deciding to overwrite or merge.

### 1.2 Files deleted entirely

| File | Reason |
| --- | --- |
| `src/shutterencoder/ui/others/Donate.java` | QR donation popup, contains `MachineId` reading the motherboard serial |
| `src/resources/qrcode.png` | Used only by the donation popup |
| `src/shutterencoder/ui/main/ImageAdjustement.java` | Stale upstream copy with a typo, references nonexistent fields, breaks compilation |

Note the `ImageAdjustement.java` entry carefully. It is not a feature we removed; it is a compile error shipped by upstream. If upstream ever fixes the spelling, restore the file and drop our deletion.

If upstream reintroduces the donation popup, it usually edits `Settings.java` in the same commit. Removing `Donate.java` makes those references fail to compile. Check the following locations (line numbers refer to upstream `20.5`):

| `Settings.java` location | Content |
| --- | --- |
| Field declarations | `savedDayOfYear` |
| Component name registration | `btnDisableUpdate.setName(...)` |
| Checkbox layout chain | `btnDisableUpdate.setBounds(...)`, anchor of `btnDisableVideoPlayer` |
| `loadSettings` | `dayOfYear` and `textMailDonate` read branches |
| `saveSettings` | `dayOfYear` write and `textMailDonate` inside `Element account` |
| Settings window footer | `JButton donate` and its `MouseListener` |

Compiler errors name the undefined symbols directly (`Donate`, `showDonateWindow`, `savedDayOfYear`), so each corresponding statement can be removed in turn.

### 1.3 Targeted edits (most likely to conflict)

| File | Change | Anchor |
| --- | --- | --- |
| `utils/Utils.java` | Exit directly with `System.exit(0)`, drop the `showDonateWindow` branch | The `//Check donate account` block at the end of `Utils.exitApp(boolean hideFrame)` |
| `ui/main/Main.java` | Remove the `showDonateWindow` field, remove the `Update.newVersion()` call, compose the version string instead of hardcoding it | `public static String actualVersion`, right after `Ytdlp.update();` |
| `ui/others/Update.java` | Remove `newVersion()` and `runProcess()` | Keep `HTTPDownload` and the progress window |
| `ui/others/Settings.java` | Remove the `dayOfYear` counter, `textMailDonate` reads and writes, the donate button, and the `btnDisableUpdate` checkbox | The `Element warning` block in `saveSettings`, and the checkbox layout chain |

**The version string is the only high-conflict point.** Upstream changes the `actualVersion` line on every release, and our version rework lives in the same place. When it conflicts, copy the new upstream version into `baseVersion` and keep everything else:

```java
public static final String baseVersion = "20.6";   // change only this line
public static final String actualVersion = buildVersion(baseVersion, readBuildRevision());
```

---

## 2. Upgrade Procedure

```bash
# 1. Update the upstream mirror (fast-forward only)
git checkout master
git fetch origin
git merge --ff-only origin/master

# 2. Rebase the delivery branch onto the new upstream
git checkout no-prompt
git rebase master
```

Resolve conflicts using the anchors above. In most cases only the `Main.java` version line needs attention.

```bash
# 3. Static audit: confirm no popup or telemetry was quietly reintroduced
powershell -ExecutionPolicy Bypass -File ./audit-noPrompt.ps1 -Strict

# 4. Build
powershell -ExecutionPolicy Bypass -File ./build-noPrompt.ps1
```

`audit-noPrompt.ps1 -Strict` returns a nonzero code on unexpected matches, so it can be used directly as a gate.

**Always audit before building.** Upstream commits are mostly wholesale `Add files via upload` uploads, so diffs are noisy and manual review misses things. The audit script is the only reliable safety net.

```bash
# 5. Verify the installed build
#    After installing the Setup.exe from build/dist:
"C:\Program Files\Shutter Encoder\Shutter Encoder.exe" --version
#    Expected: v<baseVersion>-noPrompt-<current commit>
```

### Three checks required after every rebase

A successful rebase does not mean the result is correct. Verify all three points before building.

```bash
# 1. Did the new upstream version actually land in baseVersion?
grep -n 'baseVersion = ' src/shutterencoder/ui/main/Main.java

# 2. Were upstream additions preserved? (use identifiers from that upstream commit)
grep -rn '<new field or method name>' src/shutterencoder/

# 3. Is the popup still removed?
ls src/shutterencoder/ui/others/Donate.java   # should report "No such file"

# 4. Audit and compile
powershell -ExecutionPolicy Bypass -File ./audit-noPrompt.ps1 -Strict
```

Point 1 fails easily. A conflict-free rebase can mean the upstream line change was replaced wholesale by our rewrite, leaving the version silently pinned to the old value. `baseVersion` must equal the latest upstream `actualVersion`.

---

## 3. Why Rebase Instead of Merge

Upstream rewrites many files wholesale and mixes line-ending styles, so long-lived merges fill the history with forks. Rebasing replays our patches on top of the new upstream, keeping a linear "upstream plus one patch commit" structure where `git diff master..no-prompt` always equals the real patch surface.

The tradeoff is that rebasing changes the commit hash, **so the hash embedded in the version string changes too**. Every upgrade must rebuild; old installers cannot be reused.

If a local build or an installed copy was produced from an older commit, its `--version` will not match. That is expected; reinstall.

---

## 4. Network Calls Requiring Periodic Review

The following calls are not telemetry, but they reach the network without explicit user action. If upstream adds more, decide whether to accept them.

| Location | Behavior | Disposition |
| --- | --- | --- |
| `library/Ytdlp.java` | Runs `yt-dlp -U` self-update on every start | Keep. YouTube changes constantly; without updates the web download feature stops working |
| `library/Deoldify.java` | Downloads models from HuggingFace on first colorization use | Keep. User-initiated, required for the feature |
| `library/Ytdlp.java` | Downloads the `yt-dlp` binary from GitHub when missing | Keep. Same as above |
| `functions/Translate.java` | Subtitle translation calls `translate.googleapis.com` | Keep. User-initiated |
| `Anonymizer.java`, `Whisper.java` | Opens PayPal pages for paid companion apps | Keep. User-initiated click |

The audit script prints this list on every run. New entries should be judged before being allowed through.

To forbid startup network access entirely, comment out `Ytdlp.update();` in `Main.java`. The cost is that web video download will gradually break as YouTube changes.

---

## 5. No Telemetry

The source contains no third-party analytics SDK (Google Analytics, Sentry, Mixpanel, Segment, or similar). The only device data collection was `MachineId` inside the former `Donate.java`, which read the motherboard serial and reported its SHA-256. It was removed together with the donation popup, and the audit script keeps a permanent check for it.
