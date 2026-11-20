# Claude Code sandbox

Read the exact error and the latest `[STARTUP]` line in the log named by
`start`. A permissions error can also appear before a log is created.

| Symptom | What to check |
| --- | --- |
| `Operation not permitted`, `Permission denied`, or `POSIXErrorCode: 1` while starting the IPC listener | The Simulator watcher binds a socket on `127.0.0.1`. The sandbox may deny the bind. |
| `cannot claim Simulator …` during startup | Another watcher owns the Simulator and app. Stop it from its project, or use another Simulator. |
| `warning: cannot register ownership of Simulator …` | The watcher started, but the sandbox denied its local message port. It cannot detect another watcher on the same Simulator and bundle ID, so keep one Simulator per worktree yourself. |
| Permission error creating a lock or writing `.ember/sessions`, `.ember/logs`, or `.ember/patches` | The watcher needs write access to the `.ember` directory beside the project, workspace, or context. |
| Permission error during `simctl get_app_container`, session publication, or patch transfer | Check access to the Simulator service and the installed app's data container. The watcher writes the session record and patches there. |
| `cannot signal pid …: errno 1` during `stop` | The watcher may still be running. Have the user stop that session from a terminal outside the sandbox. |

If the error indicates a sandbox denial, show the user the failing command,
working directory, and error. Ask them to run the affected command in their
terminal outside the sandbox with the same target arguments, or to configure
the needed access in Claude Code. Leave Claude Code settings, file
permissions, and project settings under the user's control. A missing
connection alone can also come from the wrong Debug build or Simulator.
