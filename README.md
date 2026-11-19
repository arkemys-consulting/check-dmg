# check-dmg

**Look inside a macOS installer before you open it.**

`check-dmg` inspects a `.dmg`, `.iso`, `.pkg`, `.zip`, `.aar` or `.app` **without running anything inside it**, and tells you in plain words what it would do to your Mac: who signed it, what runs during installation, what runs as root, where files go, and whether anything in it looks like a data stealer.

It was written after a real infection, and tested on the installer that caused it. That package wrapped the genuine, developer-signed installer of a well-known app. Once you typed your password, its post-install script disabled Gatekeeper, dropped a small app into `/Library/Application Support` and opened it. That app contained no readable text, only encrypted shell commands, and it dropped an infostealer into `/tmp`. Every sign was there, in files nobody reads. This tool reads them.

```
check-dmg ~/Downloads/Some App 2.1.dmg
```

## Why

On macOS, most infections do not come from exploits. They come from installers that people run themselves, mostly from outside the App Store:

- **Infostealers** (AMOS, Banshee, Poseidon and others) hidden in installers or "fix" scripts. They show a fake password prompt, then copy the keychain, browser passwords and cookies, crypto wallets and documents. Stolen cookies open your accounts without a password or a 2FA code.
- **ClickFix** pages that ask you to paste a command into Terminal. No Gatekeeper check ever runs on that command.
- **Install scripts** that ask for your password and disable Gatekeeper for the whole system, when one app only needed unlocking.

Gatekeeper does not look at most of this, and it does not look at all at files copied by SFTP or synced from a server, or extracted by some tools. `check-dmg` is a second pair of eyes for exactly those cases.

## What it checks

**The file**
- Size, SHA-256, download source recorded by macOS, quarantine flag.
- Disk images are mounted **read-only**, without being shown in the Finder, and ejected afterwards. An image you already opened is checked where it is.
- Images inside folders inside images (a common layout) are opened too. `.zip` and Apple Archive (`.aar`) files are extracted to a temporary folder.

**Each app**
- Signature: developer, Apple, ad hoc, unknown certificate or none; whether it is intact; whether Gatekeeper accepts it (notarization).
- Extra libraries injected at launch, helpers that will run as root at every startup, loose programs hidden in its resources.
- Apps that are really scripts in disguise: AppleScript applets (the script is decompiled and read), Platypus wrappers, shell scripts as the app's program.
- Entitlements that let outside code in (`disable-library-validation`, `allow-dyld-environment-variables`, `get-task-allow`).
- **Programs that hide what they run**: a program that calls `system()`, `popen()`, `exec*()` or `posix_spawn()` but contains almost no readable text is encrypting its commands. Placeholder identifiers such as `com.example.*` are flagged too.
- **Data stealer traces** in every compiled program: keychain dumping, browser credential files, crypto wallets, fake password prompts, data exfiltration, notes, command-and-control strings, virtual machine checks. One family alone is common in normal apps; three or more together is a red flag.
- Comparison with the copy already installed in `/Applications`: same program, a different build, or a modified repack. It handles copies slimmed by cleaner apps (Intel code removed). If your installed copy is the developer's original, it tells you to keep it.

**Each installer package (`.pkg`)**
- Signature.
- Every script and every compiled program it runs as root, extracted without unpacking the payload (a 3 GB package is checked in about 20 seconds). Compiled programs cannot be read, so they are listed with their signer, the web addresses they contain and a VirusTotal link.
- Where it writes, and whether it installs anything that starts automatically (`LaunchDaemons`, `LaunchAgents`, privileged helpers) or writes to unusual places.
- **Apps installed outside Applications** and **installers inside the installer**: only those items are extracted from the payload, then checked like any other app or package. This is how droppers hide.
- **Install scripts that open what they just installed** in a hidden or temporary folder.
- Scripts of packages signed by their developer still get warnings for risky commands, but not red flags.

**Everything else in the image**
- Scripts and `.command` files, scanned for risky commands (`curl | sh`, base64 decoding, `osascript` password prompts, `spctl --master-disable`, `launchctl`, keychain access, `sudo`). Harmless helpers that only remove the quarantine flag get a warning, not a red flag.
- `.terminal` files that run a command when opened, web and file shortcuts (including ones with invisible names), hidden files and small hidden notes.
- Readme and instruction files (`.txt`, `.html`, `.rtf`, `.nfo`): commands they ask you to type, and a warning if they ask you to weaken Gatekeeper or SIP.

**VirusTotal**
- Every fingerprint worth looking up is listed in one table, with a link.
- With a free API key, the number of detections and the threat label are shown in the table, and a file detected by 5 engines or more becomes a red flag. **Only SHA-256 fingerprints are sent, never your files.**

## Verdicts

| Verdict | Meaning |
|---|---|
| **DO NOT RUN** | At least one red flag. Do not open it and never type your password for it. |
| **DO NOT RUN THE SCRIPT** | The red flags all come from a script next to the app. The app itself looks fine: drag it to Applications and unlock that app only, as shown. |
| **CAUTION** | Warnings only. Read them and check the VirusTotal links. |
| **LOOKS CLEAN** | Nothing found. Still check the VirusTotal links. |

The exit code is `1` when there is a red flag, `0` otherwise, so the tool can be used in scripts.

## Install

Requires macOS 13 or later. Nothing else: it uses the tools that ship with macOS.

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/arkemys-consulting/check-dmg/main/check-dmg -o ~/.local/bin/check-dmg
chmod +x ~/.local/bin/check-dmg
```

Make sure `~/.local/bin` is in your `PATH`. Yes, this README asks you to run a downloaded script: read it first, it is one file.

### VirusTotal key (optional)

Create a free account on virustotal.com, copy your API key from your profile, then:

```bash
mkdir -p ~/.config/check-dmg && umask 077 && pbpaste > ~/.config/check-dmg/vt-api-key
```

Or set `VT_API_KEY` in your environment. The free key allows 4 lookups per minute: the tool waits between batches. Use `--no-vt` to skip the lookups.

## Usage

```
check-dmg [--no-vt] <file.dmg | .iso | .pkg | .zip | .aar | App.app>
```

Colors are used when the output is a terminal (`NO_COLOR=1` turns them off). In terminals that support clickable links (iTerm2, WezTerm, VS Code, Ghostty), VirusTotal links are clickable; elsewhere the full URLs are printed.

## Limits

`check-dmg` spots the usual traps. **It cannot prove that a file is safe.**

- Malware can be packed, encrypted or obfuscated so that none of its strings are visible.
- A program can wait days before doing anything, or download its real payload later.
- A package that runs a compiled program as root can do more than its file list says.
- VirusTotal only knows files someone has already submitted. "Not found" means unknown, not clean.

For anything that asks for your password, the safest habits remain: a drag-and-drop app never needs it; never paste a command from a web page into Terminal; unlock one app with `xattr -dr com.apple.quarantine /Applications/Name.app` instead of disabling Gatekeeper; and keep an outgoing firewall and a persistence monitor running (for example LuLu and BlockBlock from Objective-See).

## Tests

```bash
tests/run-tests.sh
```

The bench builds harmless fake installers (clean apps, fix scripts, ClickFix-style command files, hidden and embedded stealers, malicious and plain packages, a dropper package that hides and launches an app with encrypted commands, nested images, AppleScript and shell-script apps, Terminal files, instructions that ask to disable Gatekeeper, risky entitlements, zip and Apple Archive containers) and checks 18 verdicts. The fake stealers are tiny programs that only contain typical strings; they do nothing. It needs the Xcode command line tools (`xcode-select --install`).

## Contributing

Issues and pull requests are welcome, especially new traps seen in the wild (with a fingerprint) and false positives on legitimate software. Please add a case to the test bench with each change.

## License

MIT. See [LICENSE](LICENSE).
