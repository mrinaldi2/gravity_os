#!/bin/sh
# Installs Gravity Lens as a launchd agent that starts at login and restarts
# if it stops.  ./install.sh uninstall  removes it again.
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
cp "$(dirname "$0")/gravity_lens.py" "$HOME_DIR/gravity_lens.py"

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
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Gravity Lens installed ($LABEL). Log: $HOME_DIR/lens.log"
