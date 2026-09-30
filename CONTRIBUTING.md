# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

1. Install [Gravity](https://getgravity.build) (the demo uses its daemon) and Xcode 16 or later.
2. Start the demo world, which needs no bots of your own and spends no tokens:

   ```bash
   python3 demo/make_demo.py --serve
   ```

3. Open `GravitiOS.xcodeproj`, edit the **GravitiOS** scheme (Run → Arguments), enable the demo
   launch argument and replace `PASTE_DEMO_TOKEN` with the token the demo printed. Run it on a
   simulator. These arguments are read only in Debug builds.

No signing is needed for the simulator. For a device, put your team in `Config/Local.xcconfig`
(see the README).

## Before you open a pull request

- `python3 -m unittest discover tests` passes (the companion must keep working on Python 3.9).
- The app builds: `xcodebuild -project GravitiOS.xcodeproj -scheme GravitiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- UI changes come with a before/after screenshot from the demo world, never from real bots.
- No personal data in commits: tokens, Tailscale addresses, team IDs, real bot logs or screenshots.

## Where things are

- `GravitiOS/Core/DaemonClient.swift`: the WebSocket client for Gravity's
  [control-plane protocol](https://github.com/ahilles107/gravity/blob/main/docs/protocol.md).
- `GravitiOS/Core/Lens.swift` and `companion/gravity_lens.py`: the activity, image and report side.
- `demo/make_demo.py`: add to the demo world when a feature needs data to show.

Style: follow the code around you. Swift uses SwiftUI and Observation. Keep the companion to the
standard library.
