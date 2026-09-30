# Contributing

## Checks

```sh
bin/check
```

Runs, in order, and stops at the first failure:

1. `bash -n` on every shell script
2. `bin/check-agent-files`: no agent-instruction files (`AGENTS.md`, `.claude/`,
   `SKILL.md`, ...) anywhere in the tree; the marketplace rejects them
3. `manifest.json` parses
4. `node --test tests/model.test.cjs`: unit tests for `Model.js`
5. `omarchy plugin validate` (skipped without Omarchy)
6. `tests/harness/run.sh`: the QML harness (skipped without `quickshell`)

Skipped stages are listed at the end; "all green" means nothing was skipped.
CI runs stages 1–4 on the runner and stage 6 in an `archlinux` container with
Quickshell from `extra`. Stage 5 needs Omarchy and runs only locally, and
nothing in CI loads `Panel.qml`, which needs the Omarchy shell's `qs.*`
modules. Run `bin/check` locally before pushing.

## QML harness

`tests/harness/run.sh` loads the real `Service.qml` under
`quickshell -p` (offscreen), with `binDir` and `PATH` pointed at `tests/stub/`.
Nothing real is ever run: no `ip`, `wg`, `sudo` or notification.

- Each scenario (`s01`–`s31` in `harness.qml`) is a phase machine on a 100 ms
  ticker that drives the service through its public API and prints
  `PASS sNN` or `FAIL sNN`.
- The stubs log every call to `$WG_STUB_LOG`. `run.sh` then checks call
  counts, order and notification argv, which the QML side cannot see.
- `WG_STUB_SEQ_FILE` scripts the stubs one call at a time
  (`ip: up`, `wg-quick: fail delay=1500`, `wg-quick: hang ignore-term`); see
  `tests/stub/_seq.sh`.

To run only some scenarios, name them: `tests/harness/run.sh s14 s15`.

## Trying changes in the shell

The shell runs the installed copy in
`~/.config/omarchy/plugins/io.github.justfortheloveof.wireguard-wg0/`, which is
a git clone, not a link to your checkout. Commit, then:

```sh
omarchy plugin update io.github.justfortheloveof.wireguard-wg0 --yes
omarchy restart shell
```

Uncommitted edits are not picked up. The shell's "Local plugin changed,
reloading" log line does not recreate the service; restart the shell.

## Conventions

- Logic that can be pure goes in `Model.js`, with a node test.
- Every lane command uses an absolute path under `/usr/bin/env LC_ALL=C`, and
  every privileged one uses `sudo -n` with an exact argv matching the sudoers
  rule in the README. Adding a privileged command means changing that rule too.
- Never run `wg show wg0 dump`, `private-key` or `preshared-keys`: they print
  secret keys.
- User-facing errors say what failed and how it ended
  (`Model.cmdFail`), not what the user should do.
- Toast bodies must stay within 100 characters; the notification card elides
  after three lines. `tests/model.test.cjs` enforces this.
