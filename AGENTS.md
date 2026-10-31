# AGENTS.md

Passive macOS notifier: watches the unified log (`log stream`) and shows "Touch your YubiKey" while the card or a FIDO2 key waits for a touch. User-facing docs: `README.md`.

## Hard constraints (do not break)

1. **Passive only.** Never proxy or replace the gpg-agent or SSH agent sockets or `scdaemon-program`.
2. **Never write to `~/.gnupg`.** Reading `scdaemon.conf` to warn about missing `disable-ccid` is the only allowed access.
3. **No card commands.** No APDUs, no `gpg --card-status`, no `ykman` probing from the app.
4. **No secrets, no persistence.** Parse only process/sender path, subsystem and message. Raw log lines go to stderr only with `--verbose`.
5. **User level.** No root, no kexts, no entitlements that need Apple approval.
6. **Fail safe.** If the notifier crashes or is uninstalled, gpg, `pass`, git and SSH must work exactly as before.

## Layout

- `Sources/YKTouchCore/Detector.swift`: `logPredicate`, `LogParser` (ndjson → `busy`/`end` signals), `TouchTracker` (idle → pending → notified), `parseYubicoDevices`. Every Apple log string belongs in this file. Pure logic, no I/O.
- `Sources/YKTouchNotifier/main.swift`: flag parsing, the `log stream` child process (restarted with backoff), `ioreg` lookup for Yubico VID 0x1050, `UNUserNotificationCenter`. All state lives on the main queue.
- `Sources/selfcheck/main.swift`: assert-based checks for the parser and state machine.
- `Resources/`: `Info.plist` (bundle ID `local.yk-touch-notifier`, `LSUIElement`), `AppIcon.svg` (source) and `AppIcon.icns` (built from it, committed).
- `scripts/build-app.sh`, `install.sh`, `uninstall.sh`; `launchd/*.plist` (`__HOME__` is replaced at install).

## Commands

```sh
swift build                 # compile
swift run selfcheck         # run checks; must print no FAIL lines and exit 0
scripts/build-app.sh        # build/YK Touch Notifier.app, ad-hoc signed
scripts/install.sh          # install + load launchd agent (changes the user's machine; ask first)
```

There is no `swift test`: only Command Line Tools are assumed, and swift-testing needs full Xcode. Add new checks to `selfcheck` instead.

To debug detection by hand: stop the agent, run the binary with `--stdout --verbose`, and trigger `echo t | gpg --clearsign`. This needs a person to touch the key.

## Conventions

- Swift 5.10, macOS 13+, SwiftPM, no third-party dependencies. Keep it that way.
- Keep code small and direct. Deliberate shortcuts are marked with `ponytail:` comments that say the limit and the upgrade path.
- Notifications use the source name (`CARD`, `FIDO`) as the request identifier, so they can be removed when the touch happens.
- Logs go to the unified log under the bundle ID; launchd sends stdout and stderr to `~/Library/Logs/yk-touch-notifier.log`.
- If you change the icon, edit `AppIcon.svg`, rebuild `AppIcon.icns` (see README → App icon), and bump `CFBundleVersion`. Notification banners cache the icon by bundle ID and version.
- Call Apple's log tool as `/usr/bin/log`. In zsh, `log` is a shell builtin and fails silently when stderr is discarded.

## Open work

- Record real touch captures, then replace the synthetic lines in `selfcheck` with them.
- The manual test matrix in `README.md` has no results yet.
- Optional `--socket` output isn't built yet.
