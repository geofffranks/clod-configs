# Polytoken hook contract fixtures

Captured/derived with `polytoken 0.5.0-unstable.6` on 2026-07-12.

## Provenance

The three `pre-tool-*.json` files are complete stdin envelopes captured from the installed binary in an isolated non-interactive session. The disposable project root was `/tmp/polytoken-task1-project`, its hook file was `.polytoken/hooks.json`, and each handler consumed exactly one JSON line before returning `{"outcome":"allow"}`. The bounded command used the isolated config directory, `codex/gpt-5.6-sol`, and requested `shell_exec`, `file_read`, then `skill`. Runtime-generated `prompt_id` and `call_id` values are intentionally retained.

`post-compaction.json` is derived exactly from the installed-version hook contract documented at <https://docs.polytoken.dev/harness-engineering/hooks/>: every event carries `event` and `matcher_subject`; non-tool event matcher subjects equal the event name; no event-specific `post_compaction` fields are documented. Two bounded attempts to force compaction with reduced isolated context windows were rejected by the runtime's context-size guard before the hook fired. No undocumented fields were added.

## Validation

```sh
polytoken --config-dir "$CAPTURE_DIR" config validate --user
bash scripts/test-polytoken-contracts.sh
polytoken schemas app-config --output json >/dev/null
polytoken schemas permissions-config --output json >/dev/null
```

The pre-tool capture session was also constrained by a 45-second process alarm; it completed successfully without timeout.
