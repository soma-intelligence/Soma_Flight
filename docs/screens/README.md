# Screens

- `ios/`, `mac/`: app captures from earlier tasks (simulator and Mac window), compared with the reference by `Scripts/compare.py` into `compare/`.
- `components/`, `screens/`: ImageRenderer renders of the shared components and screens.
- `live-activity-*.png`: the Live Activity lock screen and Dynamic Island, rendered (the simulator cannot capture them).
- `final/ios/`: the Task 12 pass on the iPhone 17 Pro simulator with `-useFakes`, dark and light (home, flight detail, airport, passport, settings, search). Halved from @3x.
- `final/rendered/dark/`: a small set of key states from the snapshot suite. The full set (every screen and state, dark and light, plus the Mac settings page) is not kept in git; it regenerates with:

      SNAPSHOTS=1 swift test --package-path Packages/FlightKit --filter "ComponentSnapshotTests|LiveActivitySnapshotTests"

  and lands in `final/rendered/dark` and `final/rendered/light`. Mac window captures of the final pass are not kept either: run the Mac app with `-useFakes` (plus `-open flight`, `-open airport:KAUS`, `-tab passport`) and capture the window with `screencapture -l`.

Kept PNGs are recompressed losslessly (zlib level 9, identical pixels). Prefer adding few, small images: git keeps every version forever.
- `v1-1-overview.png`: the v1.1 screens on one labelled sheet for the owner (iOS simulator captures with `-useFakes YES`, plus the Mac windows), built by `python3 Scripts/overview.py` from `ios/v2-*.png` and `mac/v2-*.png`. The full pages (Passport, delays, aircraft stats) scroll, so they are captured from the simulator, not rendered: ImageRenderer draws a ScrollView's content blank.
