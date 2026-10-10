# Awake — native macOS prototype

Apple Silicon only; macOS 15 or newer. Menu bar only, with no Dock icon.

## Build and run

Requires Xcode 16 or newer (or command line tools providing the macOS 15 SDK).
From the setup repository, run:

```sh
dotfiles/.bin/awake --install
```

The installer builds in a temporary directory, stops the old copy only after
the build succeeds, installs in `~/Applications`, and opens the app. It also
works with `reinstall-apps awake`. Set `AWAKE_APP_DIR` to choose another install
directory. For a build only, run `bash apps/awake/build.sh` from the repository; it
writes the app to `apps/awake/build/` (set `AWAKE_BUILD_DIR` to change that).
The sun/moon menu bar icon provides all controls. No external dependencies.
This is a local ad-hoc signed build, not a notarized distribution build.
Its designated requirement is the bundle identifier rather than the ad-hoc
cdhash, so the Accessibility grant survives rebuilds.

## Controls and defaults

- Left-click the menu bar icon to toggle Keep Awake; right-click to open the menu.
- Keep Awake starts on and prevents both display and system idle sleep using
  one display-sleep assertion. There is no separate display toggle.
- Mouse Jiggle starts off. When enabled, it requests Accessibility permission.
  Grant it in System Settings → Privacy & Security → Accessibility. Awake picks
  up the grant without a relaunch.
- Jiggle interval defaults to 60 seconds; choose 30, 60, 120, or 300 seconds.
  After inactivity it posts a one-pixel movement and immediate return, never
  clicks or types. It skips while a mouse button is held, during system/display
  sleep, or while this user session is inactive. It does not promise Slack presence.
- Both toggles and the interval persist locally across launches.
- On its first launch from `/Applications` or `~/Applications`, it attempts to enable Launch at Login.
  The menu shows the actual service state and an approval link when required.
  macOS can require user approval; registration errors are displayed.
- Quit releases the sleep assertion. Normal sleep preferences apply when off.
- Explicit system sleep is respected; the saved Keep Awake setting resumes on wake.

## Scope

Docked use means lid closed, monitors connected, and power connected. This does
not implement a closed-lid override without an external display/power. Standalone
use means lid open, on battery or power. Low battery, shutdown, restart, screen
locking, and deliberate sleep are not overridden. Screen-lock behavior of the
jiggler still needs Mac testing; it never attempts to unlock the session.

All settings are local. No network operations, telemetry, accounts, or paid services.

## Validation status

Compiled and launched on an Apple Silicon Mac running macOS 27.0.1 with SDK 15.2.
The installer regression test passes. Live power assertions confirm Keep Awake
creates a PreventUserIdleDisplaySleep assertion, the off setting does not, and
process exit releases it. UI automation was unavailable; menu interaction, mouse
jiggle, login registration, and extended idle/docked checks remain unverified.

## Mac acceptance checks

1. Build with the macOS 15 SDK; verify the app launches with a menu icon and no Dock icon.
2. With other keep-awake apps stopped, enable Keep Awake and run
   `pmset -g assertions`. Confirm Awake owns a PreventUserIdleDisplaySleep assertion.
3. Leave the laptop idle past its normal sleep timeout, on battery and on power.
   Confirm the laptop and its display remain awake.
4. Dock to both monitors on power, close the lid, and leave idle past the normal
   timeout. Confirm both monitors and the Mac stay awake. Do not expect the closed
   internal display to remain lit.
5. Disable Keep Awake and confirm its assertion disappears. Normal sleep must
   return unless another app holds an assertion. Quit must also remove it.
6. Enable Mouse Jiggle without permission: verify it visibly reports the missing
   permission. Grant permission and leave idle; confirm a tiny nudge and return.
7. Test monitors arranged left/right/above, activity while typing/moving, and
   dragging with a mouse button held. Jiggle must not interfere with active use.
8. Turn Jiggle off and verify movements stop. Change the interval and confirm timing.
9. Lock the Mac, deliberately sleep it, and switch user sessions. Verify the app
   does not unlock or obstruct sleep; verify the desired state resumes after wake.
10. Quit/relaunch and log out/in. Verify settings and login registration persist;
    toggle Launch at Login off and confirm it is removed in System Settings.
11. If Slack presence matters, observe it independently while away; record the
    behavior rather than assuming posted mouse events count as activity.

## API references

- https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridledisplaysleep
- https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname
- https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()
- https://developer.apple.com/documentation/servicemanagement/smappservice
