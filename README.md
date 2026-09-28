# NextUp

A menu bar app that shows your Slack notifications and your next meeting in one icon.

- **Menu bar:** a bell with the count of Slack notifications you haven't looked at yet. When a meeting is less than an hour away, its name and a countdown appear next to the bell (`2 · Sprint planning 12m`). The countdown turns orange at 15 minutes and red at 5.
- **Popover:** click the bell. It shows the next meeting (with a **Join** button for Meet, Zoom, Teams, or Webex links), the rest of today and tomorrow, and the last 24 hours of Slack notifications. New ones have a blue dot.
- **Click to go:** a Slack row brings Slack to the front. It can't jump to the exact channel, because Slack's Mac notifications carry only the workspace ID and message timestamp, not the channel. A meeting opens the call in its desktop app when one is installed (Zoom, Teams), otherwise in the browser. Meetings without a link open in Calendar. Right-click a meeting to copy its link or show it in Calendar.
- **Reminder:** one minute before each meeting you get a banner with a **Join** button. Banners show over full-screen apps.

## How it gets the data

- **Slack:** NextUp doesn't talk to Slack. It reads the notifications Slack has already posted to macOS Notification Center, from `~/Library/Group Containers/group.com.apple.usernoted/db2/db`, read-only. You see the same DMs, mentions, and keywords that Slack would show as a banner, and no Slack app or token is needed. macOS protects that file, so NextUp needs **Full Disk Access**.
- **Meetings:** EventKit, so any account in Calendar.app works (Google, Exchange, iCloud). Declined, cancelled, and all-day events are skipped.

## Install

```bash
scripts/create-signing-identity.sh   # once: a local signing cert so macOS remembers the grants across rebuilds
scripts/build.sh                     # builds, installs to ~/Applications/NextUp.app, and launches it
```

Then:

1. Allow **Calendar** and **Notifications** when macOS asks.
2. Open System Settings › Privacy & Security › **Full Disk Access**, click **+**, and pick `~/Applications/NextUp.app`. Then click **Relaunch** in the NextUp popover.
3. If your work calendar isn't in Calendar.app, add it under System Settings › Internet Accounts.
4. Tick **Open at login** in the popover footer.

### Seeing the menu bar in full screen

By default macOS hides the menu bar in full-screen apps. To keep NextUp visible over a full-screen terminal, go to System Settings › **Menu Bar** and set "Automatically hide and show the menu bar" to **Never**.

## Debugging

```bash
# Popover with sample data, rendered to PNGs (no permissions needed)
.build/release/NextUp --snapshot /tmp/nextup

# Structure of recent Slack records, message bodies redacted. Launch through `open` so it runs
# with NextUp's Full Disk Access instead of the terminal's.
open -n ~/Applications/NextUp.app --args --dump /tmp/nextup-dump.txt
```

Settings to tweak live at the top of `AppState.swift` (countdown window, Slack history window) and `MeetingReminders.swift` (reminder lead time).

## License

MIT. See [LICENSE](LICENSE).
