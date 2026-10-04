#!/bin/sh
# Runs the XCUITest suite (UITests) against a fresh demo world, no live daemon:
#
#   scripts/ui-tests.sh [xcodebuild args…]
#
# for example `scripts/ui-tests.sh -only-testing:UITests/SmokeTests`. It starts
# demo/make_demo.py with a linked peer in its own folder and ports, erases the
# suite's own simulator, runs the tests there, and stops the demo. Answers and
# unlinks only touch that demo.
#
#   SIMULATOR       simulator name (default "iOS QA – iPhone": an iPhone 18 Pro,
#                   created when missing and erased before each run; nobody else uses it)
#   SCREENSHOT_DIR  where the tests also write their screenshots as PNG
#   DEMO_OUT, DEMO_PORT, DEMO_LENS_PORT, DEMO_PEER_PORT
#                   defaults /tmp/hermes-qa-demo, 49990, 49988, 49991; pick
#                   others when another demo uses them (make_demo.py wipes its folder)
#
# Result bundles (screenshots, contrast figures): build/ui-tests.xcresult, and
# build/ui-tests-dark.xcresult for the dark-mode checks.
set -eu
cd "$(dirname "$0")/.."
simulator=${SIMULATOR:-iOS QA – iPhone}
out=${DEMO_OUT:-/tmp/hermes-qa-demo}
port=${DEMO_PORT:-49990}
lens_port=${DEMO_LENS_PORT:-49988}
peer_port=${DEMO_PEER_PORT:-49991}
log="$out.log"
project=$(dirname "$(ls -d *.xcodeproj/project.pbxproj | head -1)")

device=$(xcrun simctl list devices available | grep -F "    $simulator (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$device" ]; then
    runtime=$(xcrun simctl list runtimes available | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-[0-9-]*' | tail -1)
    device=$(xcrun simctl create "$simulator" com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro "$runtime")
fi

for p in "$port" "$lens_port" "$peer_port"; do
    if nc -z 127.0.0.1 "$p" 2>/dev/null; then
        echo "Port $p is in use (another demo?); set DEMO_PORT, DEMO_LENS_PORT or DEMO_PEER_PORT" >&2
        exit 1
    fi
done
demo=
stop_demo() {
    kill $demo 2>/dev/null || true
    wait $demo 2>/dev/null || true
    pkill -f "$out(-peer)?/gravityd.toml" 2>/dev/null || true
    pkill -f "gravity_lens.py --port $lens_port " 2>/dev/null || true
}
trap stop_demo EXIT INT TERM
# The demo first, on a quiet machine; a second try when its daemon trips while starting.
for attempt in 1 2; do
    python3 -u demo/make_demo.py --serve --out "$out" --port "$port" --lens-port "$lens_port" \
        --peer-port "$peer_port" >"$log" 2>&1 &
    demo=$!
    tries=0
    until grep -q '^Serving' "$log"; do
        tries=$((tries + 1))
        if [ $tries -gt 180 ] || ! kill -0 $demo 2>/dev/null; then break; fi
        sleep 1
    done
    grep -q '^Serving' "$log" && break
    stop_demo
    if [ $attempt = 2 ]; then
        echo "The demo world did not start; see $log" >&2
        exit 1
    fi
done
sleep 3 # the demo's permission prompts reach the daemon just after it serves

xcrun simctl shutdown "$device" 2>/dev/null || true
xcrun simctl erase "$device"
xcrun simctl boot "$device"

# Ids the routing tests open: the designer's question and iOS Dev.
ids=$(python3 - "$out" "$port" <<'EOF'
import os, sys
sys.path.insert(0, "demo")
from make_demo import Socket
out, port = sys.argv[1], int(sys.argv[2])
ws = Socket(port)
ws.request("hello", protocol_version=2, token=open(os.path.join(out, "gravity", "secrets", "client.token")).read().strip(),
           client="ui-tests")
decision = next(d for d in ws.request("list_decisions")["decisions"] if d["title"].startswith("Which accent colour"))
bot = next(b for b in ws.request("list_bots")["bots"] if b["name"] == "iOS Dev" and not b.get("peer"))
print(decision["id"], bot["id"])
EOF
)

# Two passes, because a freshly erased simulator ignores the tests' own appearance
# switch: everything in light, then the *Dark tests with the simulator in dark.
dark="-only-testing:UITests/H003Tests/testPermissionCardContrastDark -only-testing:UITests/H003Tests/testDecisionDetailContrastDark"
run_tests() { # <result bundle> <xcodebuild args…>
    bundle=$1; shift
    rm -rf "$bundle"
    TEST_RUNNER_GRAV_TOKEN=$(cat "$out/gravity/secrets/client.token") \
    TEST_RUNNER_GRAV_PORT=$port TEST_RUNNER_LENS_PORT=$lens_port \
    TEST_RUNNER_DEMO_DECISION_ID=${ids% *} TEST_RUNNER_DEMO_BOT_ID=${ids#* } \
    TEST_RUNNER_SCREENSHOT_DIR=${SCREENSHOT_DIR:-} \
    xcodebuild -project "$project" -scheme UITests -destination "id=$device" \
        -derivedDataPath build/ui-tests -resultBundlePath "$bundle" test "$@"
}
status=0
xcrun simctl ui "$device" appearance light
run_tests build/ui-tests.xcresult \
    -skip-testing:UITests/H003Tests/testPermissionCardContrastDark \
    -skip-testing:UITests/H003Tests/testDecisionDetailContrastDark "$@" || status=1
if [ $# -eq 0 ] || echo "$*" | grep -q Dark; then
    xcrun simctl ui "$device" appearance dark
    # shellcheck disable=SC2086
    run_tests build/ui-tests-dark.xcresult $dark || status=1
    xcrun simctl ui "$device" appearance light
fi
exit $status
