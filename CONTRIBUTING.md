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

`rescanPlugins` makes a freshly linked plugin (or an edited `manifest.json`)
known — but it does not rebuild an existing bar widget. After editing any QML
or `Model.mjs`: `omarchy-restart-shell`. Bash in `bin/` needs neither.

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

`Model.mjs` runs in two engines: node (tests) and Qt's QML engine, which
parses less of the language (no spread, `async`, `flatMap`, optional
chaining). A parse error there fails silently while node stays green —
`qml-smoke.sh` catches it, so run it before pushing JavaScript.

`bin/snooze` mirrors two pieces of `Model.mjs` in bash — site expansion and
the duration grammar — each marked with a "keep in sync" comment. Change one,
change the other, or the panel will list sites the CLI refuses to block.

Any change to `bin/snooze-helper` bumps its `VERSION`. `snooze status`
compares the installed helper's version with the bundled one; a mismatch
reports `outdated`, which puts the setup prompt back in the panel.
