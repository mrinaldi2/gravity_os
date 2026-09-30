#!/bin/sh
# Installs Gravity Lens as a launchd agent that starts at login and restarts
# if it stops.
#
#   ./install.sh                    install or update
#   ./install.sh --with-files       also share your home folder with the phone's file browser
#   ./install.sh --without-files    turn the file browser off again
#   ./install.sh --with-autostart   at login, wait for Tailscale, put its address in
#                                   gravityd.toml and (re)start gravityd and Lens if needed
#   ./install.sh --without-autostart
#   ./install.sh uninstall          remove it
#
# Flags can be combined.
set -eu

LABEL="${GRAVITY_LENS_LABEL:-gravitios.gravity-lens}"
HOME_DIR="$HOME/.gravity-lens"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

AUTO_LABEL="${LABEL%.gravity-lens}.autostart"
AUTO_PLIST="$HOME/Library/LaunchAgents/$AUTO_LABEL.plist"

if [ "${1:-}" = "uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootout "$DOMAIN/$AUTO_LABEL" 2>/dev/null || true
    rm -f "$PLIST" "$AUTO_PLIST"
    rm -rf "$HOME_DIR" "$HOME/Library/Caches/GravityLens"
    echo "Gravity Lens removed."
    exit 0
fi

SOURCE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME_DIR/Gravity Lens.app"
mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents"
cp "$SOURCE/gravity_lens.py" "$SOURCE/gravity_files.py" "$SOURCE/gravity_autostart.py" "$HOME_DIR/"

# A small app runs the script, so macOS asks for folder access as
# "Gravity Lens" and lists it by that name in Privacy & Security.
# Permissions belong to the exact binary: rebuild only when the source changes.
STAMP="$(cat "$SOURCE/launcher/launcher.c" "$SOURCE/launcher/Info.plist" | shasum -a 256 | cut -c1-16)"
if [ ! -x "$APP/Contents/MacOS/GravityLens" ] || [ "$(cat "$APP/Contents/.stamp" 2>/dev/null)" != "$STAMP" ]; then
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    cp "$SOURCE/launcher/Info.plist" "$APP/Contents/Info.plist"
    clang -O2 -o "$APP/Contents/MacOS/GravityLens" "$SOURCE/launcher/launcher.c"
    codesign --force --sign - --identifier io.github.gravitios.lens "$APP" >/dev/null
    echo "$STAMP" > "$APP/Contents/.stamp"
    echo "Built Gravity Lens.app. If you had allowed folder access before, macOS may ask once more."
fi

AUTOSTART=""
for arg in "$@"; do
    case "$arg" in
        --with-files)
            printf '{\n  "files": {"enabled": true, "roots": ["~"]}\n}\n' > "$HOME_DIR/config.json"
            echo "File browsing: on for your home folder (edit roots in $HOME_DIR/config.json)." ;;
        --without-files)
            printf '{\n  "files": {"enabled": false}\n}\n' > "$HOME_DIR/config.json"
            echo "File browsing: off." ;;
        --with-autostart) AUTOSTART=on ;;
        --without-autostart) AUTOSTART=off ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/GravityLens</string>
    </array>
    <key>RunAtLoad</key><true/>
    <!-- Restarts it if it exits, e.g. when Tailscale was not up yet at login. -->
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>15</integer>
    <key>StandardErrorPath</key><string>$HOME_DIR/lens.log</string>
    <key>StandardOutPath</key><string>$HOME_DIR/lens.log</string>
</dict>
</plist>
EOF

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
# bootout returns before the old process is gone; bootstrap fails until it is.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.5
done
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Gravity Lens installed ($LABEL). Log: $HOME_DIR/lens.log"

# Autostart: a separate agent that runs at login and every 5 minutes.
if [ "$AUTOSTART" = "off" ]; then
    launchctl bootout "$DOMAIN/$AUTO_LABEL" 2>/dev/null || true
    rm -f "$AUTO_PLIST"
    echo "Autostart: off."
elif [ "$AUTOSTART" = "on" ] || [ -f "$AUTO_PLIST" ]; then
    cat > "$AUTO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$AUTO_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME_DIR/gravity_autostart.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>GRAVITY_LENS_LABEL</key><string>$LABEL</string></dict>
    <key>RunAtLoad</key><true/>
    <!-- Checks again every 5 minutes; it changes nothing when all is up. -->
    <key>StartInterval</key><integer>300</integer>
    <key>StandardErrorPath</key><string>$HOME_DIR/autostart.log</string>
    <key>StandardOutPath</key><string>$HOME_DIR/autostart.log</string>
</dict>
</plist>
EOF
    launchctl bootout "$DOMAIN/$AUTO_LABEL" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMAIN/$AUTO_LABEL" >/dev/null 2>&1 || break
        sleep 0.5
    done
    launchctl bootstrap "$DOMAIN" "$AUTO_PLIST"
    echo "Autostart: on ($AUTO_LABEL). Log: $HOME_DIR/autostart.log"
fi
