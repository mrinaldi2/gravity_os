#!/bin/sh
# Runs the XCUITest suite (UITests) against a fresh demo world, no live daemon:
#
#   scripts/ui-tests.sh [xcodebuild args…]
#
# for example `scripts/ui-tests.sh -only-testing:UITests/SmokeTests`. It starts
# demo/make_demo.py with a linked peer in its own folder and ports, runs the tests
# on the simulator, and stops the demo. Answers and unlinks only touch that demo.
#
#   SIMULATOR       simulator name (default: iPhone 18 Pro)
#   SCREENSHOT_DIR  where the tests also write their screenshots as PNG
#   DEMO_OUT, DEMO_PORT, DEMO_LENS_PORT, DEMO_PEER_PORT
#                   defaults /tmp/hermes-qa-demo, 49990, 49988, 49991; pick
#                   others when another demo uses them (make_demo.py wipes its folder)
#
# The result bundle (screenshots, contrast figures) is build/ui-tests.xcresult.
set -eu
cd "$(dirname "$0")/.."
simulator=${SIMULATOR:-iPhone 18 Pro}
out=${DEMO_OUT:-/tmp/hermes-qa-demo}
port=${DEMO_PORT:-49990}
lens_port=${DEMO_LENS_PORT:-49988}
peer_port=${DEMO_PEER_PORT:-49991}
log="$out.log"
project=$(ls -d *.xcodeproj | head -1)

for p in "$port" "$lens_port" "$peer_port"; do
    if nc -z 127.0.0.1 "$p" 2>/dev/null; then
        echo "Port $p is in use (another demo?); set DEMO_PORT, DEMO_LENS_PORT or DEMO_PEER_PORT" >&2
        exit 1
    fi
done
python3 -u demo/make_demo.py --serve --out "$out" --port "$port" --lens-port "$lens_port" \
    --peer-port "$peer_port" >"$log" 2>&1 &
demo=$!
# make_demo.py stops its daemons and Lens on SIGTERM.
trap 'kill $demo 2>/dev/null; wait $demo 2>/dev/null || true' EXIT INT TERM
tries=0
until grep -q '^Serving' "$log"; do
    tries=$((tries + 1))
    if [ $tries -gt 120 ] || ! kill -0 $demo 2>/dev/null; then
        echo "The demo world did not start; see $log" >&2
        exit 1
    fi
    sleep 1
done
sleep 3 # the demo's permission prompts reach the daemon just after it serves

rm -rf build/ui-tests.xcresult
TEST_RUNNER_GRAV_TOKEN=$(cat "$out/gravity/secrets/client.token") \
TEST_RUNNER_GRAV_PORT=$port TEST_RUNNER_LENS_PORT=$lens_port \
TEST_RUNNER_SCREENSHOT_DIR=${SCREENSHOT_DIR:-} \
xcodebuild -project "$project" -scheme UITests -destination "platform=iOS Simulator,name=$simulator" \
    -derivedDataPath build/ui-tests -resultBundlePath build/ui-tests.xcresult test "$@"
