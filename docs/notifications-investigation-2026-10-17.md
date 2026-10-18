# Why Important reminders "stopped persisting" (17 October 2026)

An investigation after the Mac demo build appeared to regress: Important
reminders no longer stayed on screen with a green tick, and later nothing
appeared at all. Conclusion: **no code regression.** Two unrelated things
changed on the test Mac, and one investigation step made it worse.

## What the code review established

- Since the shipped 1.0.0 (908712d) only two commits touch the Mac app:
  7e5400e (a comment) and 42b2c1e (keychain presence check at launch).
  Neither affects delivery.
- The uncommitted entry-point change (NSApplication started directly, to
  remove the blank "Pauselet Settings" window) was tested against the
  committed entry point: identical result, so it is cleared.
- The notification path was traced with temporary logging: authorization
  `authorized`, alert style `alert`, `center.add` succeeds, the notification
  is present in `deliveredNotifications` 1.5 s later. Nothing in the app
  removes delivered or pending notifications.
- A plain `osascript -e 'display notification ...'` produced no banner either,
  and a `CGWindowListCopyWindowInfo` probe found **no NotificationCenter
  banner window on screen** for either notification. Banners were suppressed
  system-wide on that Mac, before and after a reboot, while Notification
  Centre still received them.

## What the "green tick that stayed until dismissed" actually was

The app's own in-app card (`OverlayViews.swift`, `checkmark.circle.fill`,
grey at rest and teal-green on hover). It is the **fallback** used when
system notifications are unavailable, and an Important reminder on that path
gets a 60 s sticky minimum (`OverlayWindow.swift`, since 3842b29, August).

System Settings on the test Mac had shown Pauselet notifications set to
**No**, so 1.0.0 had been running on the fallback path there. Granting
permission during the demo preparation switched Important to real system
notifications, whose on-screen lifetime is macOS's per-app **Alert Style**
(Temporary by default, and reset to Temporary whenever permission is
re-granted). The app cannot override that; it sets `interruptionLevel =
.timeSensitive`, which governs Focus breakthrough, not persistence.

## Preview cannot demonstrate persistence

`OverlayWindow.preview` deliberately shows the in-app card for Normal and
Important instead of posting a real notification, so a preview never sits in
Notification Centre. That card has the ordinary 8 s lifetime (no 60 s
minimum). "I previewed an Important reminder and it disappeared" is by
design; only a real firing exercises the system path.

## Resolved 18 October: a Focus mode was active

Switching it off restored banners for every app, Pauselet included. The
Developer ID build cannot break through a Focus (no time-sensitive
entitlement outside the App Store), so under any Focus an Important reminder
goes straight to Notification Centre and the delivery check still counts it
as landed. The App Store build carries the entitlement in its provisioning
profile, so there Important should pierce a Focus; the direct download never
will.

## Things that gate banners on macOS, outside the app

Check these on a machine where notifications land in Notification Centre but
never show as banners:

- System Settings > Notifications > **Allow notifications when mirroring or
  sharing the display** (off by default; any screen capture, share, AirPlay
  or Sidecar session then hides every banner).
- An active **Focus**, including scheduled ones and "Reduce Interruptions".
- The app's **Alert Style**: Temporary fades, Persistent stays until
  dismissed. Re-granting permission resets it.
- Killing `usernotificationsd` to force a fresh permission prompt left banner
  display broken for the session on this Mac. Prefer a reboot, or
  `tccutil reset All <bundle id>` plus removing the app from System Settings
  > Notifications, over killing daemons.

## Never edit data.json by hand

Doing so during this investigation produced `data.corrupt.json`: a schedule
written with a guessed shape fails to decode, the store copies the file to
`data.corrupt.json` and reseeds the defaults. If test data is needed, let the
app seed it, then change it through the editor.

## Decision, 18 October: Important is the app's own sticky card on the Mac

Implemented. `OverlayWindow.present` routes `.important` to `showImportant`,
a second corner slot (`ImportantCardView`) with Done and Snooze that never
self-dismisses, plays the tier sound itself, and pushes a Subtle card beneath
it while both are up. Preview shows the same card. Only Normal still goes
through `UNUserNotificationCenter`, so the notifier's fallback no longer
needs a 60 s minimum. iOS keeps Important as a time-sensitive notification
(an app there cannot show its own window in the background); Windows is
unchanged and noted in PARITY.md.
