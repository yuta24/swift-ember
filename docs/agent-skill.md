# Using swift-ember with Claude Code

Install the host CLI and configure the app for Debug hot reload before using
the skill. Use a CLI build that lists `skill` in `swift-ember --help`. Open the
app's repository in Claude Code and ask it to check a Swift edit with swift-ember.
The skill starts the background watcher, reads patch results, verifies the
running app, and stops the watcher when finished.

```sh
swift-ember skill install          # Project scope
swift-ember skill install --global # User scope
swift-ember skill status
swift-ember skill uninstall
```

The default destination is `<git-root>/.claude/skills/swift-ember`, or the same
relative path under the current directory outside Git. `--global` uses
`~/.claude/skills/swift-ember`. `--dir` takes the parent skills directory, with
relative paths starting from the current directory. Unscoped `status` shows
both project and global destinations.

The CLI finds the source beside a release binary, in the installed prefix's
`share/swift-ember` payload, or in a swift-ember checkout. If you copied only
the binary from a source build, set `SWIFT_EMBER_HOME` to the checkout root.
It also accepts an extracted release root.

Rerun `install` with the same scope to update. `status` flags a different CLI
version, different available source content, or local edits. A local edit,
addition, or missing file is listed when it prevents an update or removal.
`install --force` replaces the destination after discarding local changes.
`uninstall --force` discards changes to a copy with swift-ember's installation
record. Copies without that record are left in place by uninstall.

The skill source starts at [SKILL.md](../skills/swift-ember/SKILL.md). Its
[reference index](../skills/swift-ember/reference.md) links to the topic guides.
