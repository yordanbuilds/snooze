# Contributing

Issues and pull requests are welcome.

## Development

Snooze runs from its checkout. Put it where Omarchy loads plugins from — a
clone or a symlink, under the plugin's exact id, because that is the path the
widget shells out to:

```bash
git clone https://github.com/yordanbuilds/snooze.git ~/.config/omarchy/plugins/yordanbuilds.snooze
omarchy plugin enable yordanbuilds.snooze
```

Working on a checkout you keep elsewhere:

```bash
ln -sfn ~/code/snooze ~/.config/omarchy/plugins/yordanbuilds.snooze
omarchy-shell shell rescanPlugins
```

`omarchy-shell shell rescanPlugins` is what makes a freshly linked plugin — or
an edited `manifest.json` — known to the running shell. It does not rebuild a
bar widget that already exists: an instantiated widget keeps the QML it was
built from, so `omarchy-restart-shell` after editing `BarWidget.qml`,
`EditView.qml`, `Service.qml` or `Model.mjs`. Bash in `bin/` needs neither —
the widget shells out to the CLI fresh every time.

Run `snooze setup` once so the helper is in place; after that everything but
the helper itself can be developed without sudo.

## Tests

```bash
node --test "tests/**/*.test.mjs"   # Model.mjs unit tests
bash tests/scripts.test.sh          # CLI + helper, sandboxed — no sudo, no live session
bash tests/qml-smoke.sh             # Model.mjs in the real QML engine, plus qmllint
omarchy plugin validate .           # manifest against the plugin schema
```

All four run green before every commit; please add tests for behavior you
change. The script tests drive the helper through its non-root `--hosts-file`
seam and never touch the real `/etc/hosts` — keep it that way, and never write
a test that needs `sudo`.

## Keeping the two halves in step

`Model.mjs` is loaded by two JavaScript engines: node (tests) and Qt's QML
engine (the plugin itself). The QML engine parses less of the language — no
object spread or rest, no `async`, no `flatMap`/`at`/`fromEntries`, no optional
chaining — and a parse error there makes the plugin silently fail to load while
`node --test` stays green. `qml-smoke.sh` exists to catch exactly that, so run
it before pushing JavaScript changes.

`bin/snooze` re-implements two pieces of `Model.mjs` in bash, because the CLI
must work with no shell running: the site expansion (`expandSites` →
`expand_groups`'s jq pipeline) and the duration grammar (`parseDuration`,
`formatRemaining` → `parse_duration`, `fmt_remaining`). Both sites carry a
"keep in sync with Model.mjs" comment. Change one and you change the other, or
the panel will list sites the CLI then refuses to block.

Any change to `bin/snooze-helper` — behavior, validation, anything — bumps its
`VERSION`. `snooze status` asks `/usr/local/bin/snooze-helper` for its version
and compares it with the `VERSION=` line in the plugin directory it is running
from; a mismatch reports `outdated`, which is what puts the setup prompt back
in the panel. Without the bump, users keep running the old helper and nothing
tells them.
