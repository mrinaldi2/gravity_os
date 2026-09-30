#!/bin/sh
# Installs Gravity Lens as a launchd agent that starts at login and restarts
# if it stops.
#
#   ./install.sh                    install or update
#   ./install.sh --with-files       also share your home folder with the phone's file browser
#   ./install.sh --without-files    turn the file browser off again
#   ./install.sh uninstall          remove it
set -eu

LABEL="${GRAVITY_LENS_LABEL:-gravitios.gravity-lens}"
HOME_DIR="$HOME/.gravity-lens"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$HOME_DIR" "$HOME/Library/Caches/GravityLens"
    echo "Gravity Lens removed."
    exit 0
fi

mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/gravity_lens.py" "$(dirname "$0")/gravity_files.py" "$HOME_DIR/"

case "${1:-}" in
    --with-files)
        printf '{\n  "files": {"enabled": true, "roots": ["~"]}\n}\n' > "$HOME_DIR/config.json"
        echo "File browsing: on for your home folder (edit roots in $HOME_DIR/config.json)." ;;
    --without-files)
        printf '{\n  "files": {"enabled": false}\n}\n' > "$HOME_DIR/config.json"
        echo "File browsing: off." ;;
esac

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$HOME_DIR/gravity_lens.py</string>
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
