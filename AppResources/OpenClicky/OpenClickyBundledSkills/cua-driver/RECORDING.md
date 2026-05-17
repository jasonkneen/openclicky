# Recording & replaying trajectories

This is upstream reference material only. OpenClicky's default managed
runtime does not expose Computer Use recording or replay tools.

## OpenClicky Behavior

- Do not try to enable recording or replay from a child worker.
- Do not shell out to `cua-driver` recording commands.
- Do not describe recording or replay as available unless the runtime
  explicitly exposes those tools.
- If the user asks to record, replay, export, or regenerate a Computer
  Use trajectory, stop and explain that this build cannot do it through
  Computer Use.

## Upstream Concept

Standalone Cua can capture action sequences plus before/after state for
demos, regression diffs, or training data. That upstream mode records
action inputs, post-action snapshots, screenshots, and timing metadata
into per-turn folders.

That information is useful context for a future OpenClicky runtime, but it
is not a callable surface in this release. The only shipped Computer Use
loop is:

1. Snapshot with `get_window_state`.
2. Act with currently exposed MCP tools such as `click`, `set_value`,
   `type_text`, `press_key`, `hotkey`, `scroll`, `page`, or
   `launch_app`.
3. Re-snapshot and verify.

For regression evidence in this build, save screenshots, logs, and a
plain-language step list instead of trying to record or replay a
trajectory.
