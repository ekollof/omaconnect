# OMAConnect — KDE Connect for the Omarchy bar

`ekollof.omaconnect` puts your phone in the Omarchy bar: pairing, battery,
notification replies, file sharing, ping, and find-my-phone. The KDE Connect
protocol (TLS, discovery, pairing, crypto) is handled by the
**[`kcd`](https://github.com/bethropolis/kcd)** daemon — this plugin is a thin
quickshell frontend over its CLI and live event stream. No protocol code lives
in QML.

## Prerequisites

```bash
yay -S kcd-bin        # daemon (>= 1.17.0) + systemd user unit + firewall rules
```

Recommended optional deps (all present in `kcd-bin`'s optdepends):

- `libnotify` — phone notifications with icons via `notify-send`
- `wl-clipboard` — clipboard push (`kcd clipboard`)
- `sshfs` — SFTP file browsing (v2 feature)
- `ydotool` — phone-as-trackpad (handled entirely by the daemon)

The phone needs the [KDE Connect Android app](https://kdeconnect.kde.org/)
on the same network.

## Install

```bash
omarchy plugin add https://github.com/ekollof/omaconnect.git --enable
```

Then enable the widget in the bar (default section: right), or:

```bash
omarchy plugin enable ekollof.omaconnect
```

## First run

1. Click the 󰄜 pill. If the daemon is stopped, the panel offers a
   **Start kcd daemon** button (runs `systemctl --user enable --now kcd` —
   only on explicit click, never automatically).
2. Open KDE Connect on the phone — the desktop appears. Either accept the
   phone's pair request from the panel (**Accept pair**) or send one
   (**Pair**) and accept on the phone. The panel always shows the device
   name + full ID before you trust it (trust-on-first-use).
3. Firewall: `kcd-bin` ships the rules (1716 TCP/UDP discovery + control,
   1739–1764 TCP file transfers). Manual installs: allow those ports.

## What works (MVP)

- **Devices + pairing**: discovered/paired/offline states, pair/unpair with
  optimistic "Pair requested…" state.
- **Bar pill**: phone glyph + battery % with charging indicator.
- **Notification replies**: replyable phone notifications (WhatsApp, SMS,
  …) appear in the panel's reply section; answers go out via `kcd reply`.
  Display itself needs no plugin code — kcd forwards through `notify-send`,
  so toasts land in Omarchy's notification history/DND like any other app.
- **Share**: send a file to the primary device; incoming files/links/text
  raise toasts pointing at the download dir.
- **Quick actions**: ping, find-my-phone (ring), call mute hint on incoming calls.
- **Phone files (SFTP)**: list volumes, mount into the file manager,
  unmount. Needs `sshfs` (optdepend of `kcd-bin`).
- **SMS**: compose by number, incoming messages appear in the panel and as
  toasts. I won't send a test SMS for you — that one's yours to try.
- **Phone media (MPRIS)**: now-playing title/artist with play/pause toggle,
  previous/next. Shows "No media playing" when the phone is quiet.
- **Clipboard push**: per-device "Clip" button sends the desktop clipboard
  to the phone (daemon handles sync; needs `wl-clipboard`).

## IPC

```
qs ipc call ekollof.omaconnect toggle
qs ipc call ekollof.omaconnect refresh
```

## Validate / lint

```bash
omarchy plugin validate /home/ekollof/src/omaconnect
qmllint -I "$OMARCHY_PATH/shell" /home/ekollof/src/omaconnect/*.qml
```

## Troubleshooting

**Phone says "Failed receiving file"**: file transfers need the phone to
open a TCP connection *back* to the desktop (ports 1739–1764), while the
control channel usually works because the desktop dials *out*. With
Omarchy's default-deny `ufw`, allow the pre-installed kcd profile:

```bash
sudo ufw allow kcd
sudo ufw reload
```

(`kcd-bin` ships the profile; it just isn't enabled automatically.)

## Known quirks

- **IPC answers lag one reload behind**: after `omarchy plugin update`,
  the panel UI refreshes immediately but `omarchy-shell ekollof.omaconnect …`
  keeps hitting the pre-update handler instance (first-registered wins and
  old instances linger). A shell restart promotes the new code. Symptom:
  new IPC functions report "Function not found" until restart.

## Roadmap (v2)

SFTP browse/mount opener, SMS compose, MPRIS phone-playback controls,
clipboard toggle, direct Unix-socket IPC instead of process spawns.
