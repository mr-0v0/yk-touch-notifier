# YK Touch Notifier

<img src="Resources/AppIcon.svg" width="128" alt="App icon: a hand pressing a YubiKey contact">

Shows a macOS notification ("Touch your YubiKey") while the YubiKey waits for a touch (gpg sign/decrypt, SSH through gpg-agent, `pass`, FIDO2), and removes it after the touch or timeout.

**Passive:** it only reads the unified log (`log stream`). It doesn't proxy gpg-agent or SSH sockets, sends no card commands, doesn't touch `~/.gnupg`, and runs as your user. If it crashes or is removed, gpg/SSH behave exactly as before.

It relies on `disable-ccid` in `~/.gnupg/scdaemon.conf`, so card traffic goes through CryptoTokenKit and gets logged. It warns at startup if that line is missing.

Detection logic is ported from [yubikey-touch-detector](https://github.com/max-baz/yubikey-touch-detector) (ISC, see `THIRD_PARTY_NOTICES`).

## Install / uninstall

```sh
scripts/install.sh     # build, copy to ~/Applications, load launchd agent; allow notifications when asked
scripts/uninstall.sh
```

Requires Xcode Command Line Tools (Swift 5.10+). `SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh` signs for distribution; then notarize with `xcrun notarytool submit … --wait` and `xcrun stapler staple`.

## Layout

| Path | |
| --- | --- |
| `Sources/YKTouchCore/Detector.swift` | log predicate, parser, touch state machine (all Apple log strings live here) |
| `Sources/YKTouchNotifier/main.swift` | flags, `log stream` child process, notifications |
| `Sources/selfcheck/main.swift` | assert-based checks |
| `Resources/` | `Info.plist`, app icon (`AppIcon.svg` source, `AppIcon.icns` built) |
| `scripts/` | build, install, uninstall |
| `launchd/` | user agent plist (`__HOME__` is replaced on install) |

## Flags

| Flag | Default | |
| --- | --- | --- |
| `--threshold-ms N` | 600 | wait before notifying (skips merely slow operations) |
| `--gap-ms N` | 1500 | card counts as idle after this long without a time extension |
| `--no-fido` | | ignore FIDO2/U2F |
| `--stdout` | | print `CARD_1`/`CARD_0`/`FIDO_1`/`FIDO_0` instead of notifying |
| `--verbose` | | print matched raw log lines to stderr (debugging only) |

To change flags for the agent, add them to `ProgramArguments` in `launchd/*.plist` and re-run `install.sh`.

## Checks

`swift run selfcheck` runs the parser and state-machine checks. They're assert-based because `swift test` with swift-testing needs full Xcode.

## App icon

`Resources/AppIcon.svg` is the source. After editing it, rebuild the `.icns` (needs `brew install librsvg`):

```sh
d=$(mktemp -d)/AppIcon.iconset; mkdir -p "$d"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s Resources/AppIcon.svg -o "$d/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) Resources/AppIcon.svg -o "$d/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$d" -o Resources/AppIcon.icns
```

Then bump `CFBundleVersion` in `Resources/Info.plist` and run `scripts/install.sh`. macOS caches notification icons by bundle ID and version, so without the bump banners keep showing the old icon.

## Troubleshooting

- No notification: check Focus/Do Not Disturb, System Settings → Notifications → YK Touch Notifier, and `~/Library/Logs/yk-touch-notifier.log`.
- Run `"~/Applications/YK Touch Notifier.app/Contents/MacOS/yk-touch-notifier" --stdout --verbose` (stop the agent first), then `echo t | gpg --clearsign`.
- Notification flickers while waiting: raise `--gap-ms`.
- Own log messages: `/usr/bin/log stream --predicate 'subsystem == "local.yk-touch-notifier"'`. In zsh, plain `log` is a shell builtin, so use the full path.
- Old or blank icon on notifications (System Settings shows the right one):
  - Bump `CFBundleVersion` and reinstall.
  - Check that no stale copy is registered under the same bundle ID: `lsregister -dump | grep -B5 local.yk-touch-notifier` (`lsregister` lives in `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`). Remove one with `lsregister -u <path>`, then `killall usernoted NotificationCenter`.
  - If it still shows, restart the Mac.

## Known limitations

- Depends on undocumented Apple log messages; may break in a macOS update. Tested: macOS 27.0.1.
- "Time extension" means the card is busy, not strictly waiting for a touch. Slow operations (RSA keygen) can trigger it.
- Over SSH into the Mac, the notification still appears on the Mac's screen.

## Manual test matrix

| Case | Expected | Result |
| --- | --- | --- |
| `echo t \| gpg --clearsign`, sig touch on | notify ~1 s, clears on touch | |
| `pass show <entry>`, dec touch on | notify, clears | |
| `ssh -T git@<host>`, aut touch on | notify, clears | |
| no touch, times out | clears when card stops | |
| touch off / cached within 15 s | none | |
| PIN prompt 10 s, then PIN, then touch | only after PIN | |
| `gpg --card-status`, plug/unplug, `ykman info` | none | |
| FIDO2 on webauthn.io | FIDO notification | |
| kill notifier mid-operation | gpg/ssh unaffected, launchd restarts | |
| uninstall | everything works as before | |

## License

MIT, see `LICENSE`. Third-party notices are in `THIRD_PARTY_NOTICES`.
