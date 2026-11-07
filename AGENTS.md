# iwifyou

Native macOS app (main window plus menu bar item) for the ZTE F460 admin panel: connected devices and MAC-filter blocking, WLAN info, channel quality and switching, and router restart.

- Use conventional commit messages, for example `feat:`, `fix:`, or `chore:`.
- Build with `swift build`; run checks with `swift test`.
- Package the application with `./scripts/build-app.sh`.
- Router captures, cookies, credentials, and Wi-Fi passwords must never be committed.
- Do not submit changes to a real router while testing without an explicit channel change requested by the user. Use the local simulator or demo mode.
- Unsupported firmware must fail closed; never guess an endpoint or a configuration payload.
