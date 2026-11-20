# Reading save results

For `start`, read the file it prints on the `log` line. The file is
`.ember/logs/<scheme-or-context>-<session-hash>.log` beside the Xcode
project, workspace, or context file. Its stdout and stderr include startup,
runtime connections, patch acknowledgements, and diagnostic blocks.
`watch` emits the same save results to its terminal.

## Wait for a save

Run each code block in its own Claude Code Bash call, from the same working
directory. Before editing, replace the example log path with the exact path
printed by `start`. This records the path and first unread line for the next
call. Keep the cursor in the `.ember` directory that holds the log, which is
beside the project, workspace, or context file. Use an absolute path, and a
separate cursor file for each concurrent session.

```bash
(
  log='/absolute/path/from/start.log'
  cursor='/absolute/path/to/.ember/claude-save.cursor'
  count=$(wc -l < "$log") || exit 1
  mkdir -p "$(dirname "$cursor")" || exit 1
  printf '%s\n%s\n' "$log" "$((count + 1))" > "$cursor"
)
```

Save one coherent edit. Then run the entire block below in one Bash call.
The cursor path must match the previous call. The loop checks only lines
written after that cursor, waits up to 30 seconds, and exits as soon as it
sees an `Action:` line, `Not patching:`, or a complete `hot reloaded` block
ending in the timing total.

```bash
(
  cursor='/absolute/path/to/.ember/claude-save.cursor'
  { IFS= read -r log && IFS= read -r first; } < "$cursor" || exit 1
  deadline=$((SECONDS + 30))
  while :; do
    new_lines=$(tail -n "+$first" "$log") || exit 1
    if grep -Eq '^Action: |^Not patching:' <<< "$new_lines" ||
       { grep -q '^hot reloaded ' <<< "$new_lines" &&
         grep -Eq '^total[[:blank:]]+[0-9]+ ms$' <<< "$new_lines"; }; then
      printf '%s\n' "$new_lines"
      exit 0
    fi
    if (( SECONDS >= deadline )); then
      printf '%s\n' "$new_lines"
      printf '%s\n' 'Timed out after 30 seconds without a reload result.' >&2
      exit 1
    fi
    sleep 1
  done
)
```

A result can be a rejection even when the wait exits 0. Read the printed
block to classify it. The file watcher polls every 150 ms. Cold compilation,
large builds, and transfers can exceed the first wait. A timeout can also
mean there was no effective body change, the file is unwatched, or the
runtime disconnected. Check the latest `watching …` and connection lines.
If the same save is still pending, keep the cursor for another bounded wait.
Record a new cursor before the next save and whenever the watcher restarts.

## Applied

`hot reloaded <count> declaration(s) in <ms> ms  (g<number>)` precedes the
declaration names and a stage timing table. Match the names in the new block to
the edit. Read any `carried:`, `not verified:`, `refreshed:`, or
`already ran:` lines. An acknowledgement means the image was loaded. For
`not verified:`, confirm the behavior directly. For `already ran:`, recreate the
affected controller if it is per-instance, or build and relaunch for a
process-wide startup method.

## Rejected or rebuild required

Read the whole block, starting with the stage and subject. The reason can span
multiple lines.

| Stage | Where to look |
| --- | --- |
| `[WATCH]` | Source scanning, file removal, or a startup or build-baseline problem |
| `[CLASSIFY]` | Source ownership and edits that cannot preserve the running program's structure |
| `[GENERATE]`, `[COMPILE]`, `[LINK]` | Patch source generation, compiler diagnostics, or linking |
| `[TRANSFER]`, `[LOAD]` | Delivery or loading the image into the running app |
| `[REGISTER]`, `[VERIFY]` | Runtime evidence for replacements and verification |

Use the printed `Action:` line to choose the next step. `fix the source and save
again.` covers recoverable errors such as Swift compiler diagnostics.
`full rebuild required.` calls for a new Debug build and relaunch.
`fix the project configuration.` calls for checking target membership and setup.
`restart the app.` or `Not patching: this process cannot be described any more.`
calls for a fresh app process. If the build changed, restart the watcher as well.
`wait for source writes to finish and retry the command.` calls for waiting
until the source tree is stable.

Adding a stored property in XcodeApp produces this block.

```text
[CLASSIFY] Cart.swift
something outside a replaceable declaration changed, such as a type's declaration, an import, or a stored property

Action: full rebuild required.
```

When an opted-in automatic recovery starts, the log prints
`automatic rebuild requested; running in …`. Wait for
`automatic rebuild complete; watching pid … from a fresh baseline`, or read
`automatic rebuild failed: …` and its reason. A completed rebuild starts a
new baseline for later saves.
