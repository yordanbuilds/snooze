# Snooze

**Block the sites that eat your morning — for an hour, or until you say stop.**

![The Snooze panel](shots/idle.png)

A bar widget for [Omarchy](https://omarchy.org). Pick the groups you want out
of the way, pick a duration, and Snooze writes a marked block of `0.0.0.0`
entries into `/etc/hosts` — then takes it out again when the time is up. The
block sits in the system resolver, so it covers every browser, every profile,
every Electron app and every terminal on the machine: no extensions, no proxy,
nothing to install per browser.

Snooze is friction, not a wall. Anyone who really wants a feed can stop the
session, use their phone, or edit a file. That is the point: it interrupts the
reflex of opening a tab you didn't decide to open, and it never pretends to be
more than that.

## Installation

Snooze needs Omarchy 4 or newer.

```bash
omarchy plugin add https://github.com/yordanbuilds/snooze.git --enable
```

Enabling asks which bar section the widget goes in (default: right). The icon
appears with a dot on it — Snooze needs a one-time setup before it can touch
`/etc/hosts`. Click the icon, then **Run setup**. A floating terminal opens,
prints exactly what it is about to do, and asks for your password once:

- installs the helper root-owned at `/usr/local/bin/snooze-helper`
- writes `/etc/sudoers.d/snooze`, validated with `visudo -cf` before it lands:
  `%wheel ALL=(root) NOPASSWD: /usr/local/bin/snooze-helper`
- links the `snooze` CLI into `~/.local/bin`
- seeds `~/.config/snooze/groups.json` with the default groups

That standing passwordless rule points at one small root-owned script whose
only power is to write `0.0.0.0 <validated-domain>` lines inside its own marked
block of `/etc/hosts` — the worst anything can do through it is block a site.
It cannot point a name at a real address, cannot write outside its block, and
takes no input but its own argv.

Want to read the plan before running it? `snooze setup --print` prints every
privileged command and runs none of them (the reversible half — your groups
file and the `~/.local/bin` link — happens either way).

Updating? `omarchy plugin update yordanbuilds.snooze && omarchy restart shell`.
If the update changed the helper, the panel asks you to run setup again.

## Usage

Click the bar icon: groups, a duration, one button. Once a session is running,
the panel is the countdown.

![A running session](shots/active.png)

Timed sessions end themselves; an ∞ session runs until you press **Stop**,
which is behind a confirm. **+30 min** is there whenever a deadline is.

The time left rides along in the bar:

![Snooze in the bar](shots/bar.png)

Turn that off with the widget's _Show remaining time in bar_ setting.

| Shortcut                    | What happens                                   |
| --------------------------- | ---------------------------------------------- |
| <kbd>←</kbd> / <kbd>→</kbd> | Pick a duration                                |
| <kbd>Enter</kbd>            | Snooze — or run setup, whichever is up         |
| <kbd>Esc</kbd>              | Back out of the confirm, the editor, the panel |
| middle-click the bar icon   | Re-read the status now                         |

### Groups

![Editing a group](shots/edit.png)

Three groups ship by default. The pencil edits all of them — add, rename,
delete, add or remove sites — and anything that isn't a domain is refused. It
all lands in `~/.config/snooze/groups.json`, plain JSON you can keep in your
dotfiles and hand-edit while the panel is open:

```json
{
  "version": 1,
  "groups": [
    { "id": "social", "name": "Social", "icon": "󰙯",
      "sites": ["facebook.com", "instagram.com", "x.com"] }
  ]
}
```

Sites are bare domains. A two-label domain also blocks its `www.` form, so
`x.com` covers `www.x.com`; anything deeper is taken as written, which is why
Video ships `youtube.com`, `m.youtube.com` and `youtu.be` as three entries.

A session is a snapshot: edits apply to the next one, never to the block
already in place.

### The CLI

Everything the panel does is also a command:

```text
snooze start --group social --for 2h   block those groups (default: all) for that long
snooze start --forever                 block until you stop it
snooze extend 30m                      push the current deadline further out
snooze stop                            unblock everything now
snooze status                          what is blocked, and for how long
snooze status --json                   the same, for scripts
snooze sweep                           drop the block if its time is up
snooze setup [--force] [--print]       install the helper and its one sudo rule
snooze uninstall                       remove the helper, the rule and the link
```

Durations look like `30m`, `2h` or `1h30m`. `--group` takes the group's id —
the `id` field in `groups.json`, which for a group made in the panel is its
name, slugified — and repeats for as many groups as you want; leave it out and
every group is in.

Nothing needs the shell to be running: `snooze` is a bash script that reads
`/etc/hosts`, and `status` never escalates at all. A user timer sweeps an
expired session away — and if the machine was asleep or off at the deadline,
the widget sweeps it on the next shell start.

## Known limits

Worth knowing before you trust it with a deadline:

- **Browsers cache DNS.** Chromium holds a name for about a minute and keeps
  open connections alive, so a tab that is already loaded can survive the start
  of a session. Closing the tab is enough.
- **Secure DNS bypasses `/etc/hosts` entirely.** With DNS-over-HTTPS on, the
  browser resolves names over the network and never consults the system
  resolver, so Snooze cannot touch it. In Chromium: **Settings → Privacy and
  security → Security → Use secure DNS**, off. Firefox has the same switch
  under **Privacy & Security → DNS over HTTPS**.
- **No wildcards.** `/etc/hosts` matches exact names, so `reddit.com` says
  nothing about `old.reddit.com`. The defaults ship the variants that matter;
  add your own in the edit view.
- **Docker containers inherit the block.** Omarchy points Docker's DNS at the
  host (`"dns": ["172.17.0.1"]` in `/etc/docker/daemon.json`, answered by
  systemd-resolved), so container lookups see the same hosts entries. A
  container started with its own `--dns` does not.
- **It is bypassable, deliberately.** `snooze stop` is one click, your phone is
  right there, and `/etc/hosts` is a text file. Friction, not a wall.

## Uninstall

```bash
snooze uninstall
```

One command for all of it. It prints what it is about to remove and asks first:
anything still blocked is unblocked, then the helper, `/etc/sudoers.d/snooze`,
the `~/.local/bin/snooze` link and the session state go, and the plugin itself
is handed to `omarchy plugin remove`. One sudo prompt covers the privileged
half.

Your groups are a separate question, asked separately. Answer no and
`~/.config/snooze/` stays exactly where it is, waiting for you to come back.

## License

Snooze is open-source software licensed under the [MIT license](LICENSE).
