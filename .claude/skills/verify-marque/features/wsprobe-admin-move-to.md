# Thin WS probe (admin + move_to refuse)

Agents assert admin bus replies and retired `move_to` refusal with the in-repo
thin helper — not a scratch-directory socket client, and not a second game
client.

## Helper

- Library: `server/internal/wsprobe` — dial `/ws`, drain join, send admin or raw
  one-key JSON, await `admin_reply` / `error`.
- CLI: `go run ./cmd/wsprobe` from `server/` (build with the same module).

Examples against a running marqued (`-admin` when probing authorized commands):

```bash
go run ./cmd/wsprobe -addr 127.0.0.1:PORT -admin '/heal' -expect-prefix 'ok:'
go run ./cmd/wsprobe -addr 127.0.0.1:PORT -raw '{"move_to":{"x":1,"z":2,"seq":1}}' -expect-error-re move_to
```

Success marker: last stdout line `WSPROBE OK`. Pair with GAMELOG asserts on
`admin` / `move_to_rejected` from server stdout as in other recipes.

## Sub-features

- `wsprobe-admin` — `/heal` (or `/give`) yields `admin_reply` `ok:` and GAMELOG
  `admin` with `result=ok`.
- `wsprobe-move-to-refuse` — raw `move_to` yields `error` with `re=move_to` /
  `illegal_sample`, GAMELOG `move_to_rejected` reason `illegal_sample`.

## Gotchas

- Keep this thin: no prediction, no intent queue, no Godot. Specialized demos
  (e.g. class-kit `/give` loops) may wrap the same package.
- `move_to` is refused at the protocol boundary; do not expect a path broadcast.
