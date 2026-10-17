# Managing Backend and GlitchTip as Separate Make Targets

This document explains why the Makefile splits stack management into
independent backend and GlitchTip targets, what each target does, and the
operational lessons from this project that motivated the split.

## Why split them?

The stack has two halves with different lifecycles:

| Half | Services | Changes when |
|---|---|---|
| **backend** | `backend` (Rust/axum) | every code edit — needs rebuild |
| **glitchtip** | `db`, `valkey`, `cold-storage-init`, `glitchtip` (web) | almost never — config only |

Restarting one should never touch the other:

- A backend rebuild is a daily action; restarting GlitchTip alongside it
  risks the known embedded-worker instability ("web restart silently kills
  the worker half", see `glitchtip-cold-storage.md`).
- A GlitchTip restart/re-config (e.g. after changing env) does not need to
  rebuild the Rust image — which takes minutes.
- Debugging is much easier when you can bounce one side and watch the other
  stay untouched.

There is also a third lifecycle that must be treated separately: the
**Postgres data volume**. Resetting it invalidates every project DSN key
(they live in the DB), which silently breaks ingestion — see the
"DSN rotation" section below.

## Targets

### Backend

```sh
make up-backend      # rebuild image + start backend only
make down-backend    # stop/remove backend only
make logs-backend    # tail backend logs
```

### GlitchTip

```sh
make up-glitchtip    # start db, valkey, cold-storage-init, glitchtip web
make down-glitchtip  # stop glitchtip web only (db/valkey keep running)
make logs-glitchtip  # tail glitchtip web logs
```

`down-glitchtip` deliberately keeps `db` and `valkey` running: they hold the
state (spans, logs, DSN keys, worker heartbeats) and restarting them is
rarely wanted. To tear everything down, use the original
`make compose-down`.

### Unchanged

`make compose-up` / `compose-down` still manage the whole stack at once,
and `make check-glitchtip` / `make send-test-log` are GlitchTip-side
diagnostics independent of the backend.

## Verification workflow after a backend change

```sh
make up-backend                 # rebuild + restart backend only
curl localhost:3000/api/span    # generate a transaction + child spans
make check-glitchtip            # GlitchTip side stays up; watch section 5
```

`performance_spanstaging` should show one row per `#[tracing::instrument]`
span (INFO level) within seconds of the request.

## Lesson learned: a DB reset silently invalidates all DSNs (2026-10-17 18:00)

During debugging, the Postgres volume was recreated. Consequences:

- The project DSN key changed (`projects_projectkey` was reseeded).
- The backend kept sending with the old key in `SENTRY_DSN`.
- GlitchTip answered `403 {"detail": "Denied"}` to **every** envelope —
  with **no error in the backend's own logs** (the rejection is only
  visible with `ClientOptions::debug(true)` or in GlitchTip's
  `Forbidden: /api/1/envelope/` access log).
- Stale rows from before the reset kept showing up in the UI, which looked
  like "the pipeline works sometimes" — it did not; nothing new was
  ingested for hours.

### Detection

```sh
# any Denied responses from the SDK side?
grep -a 'Denied' <app log>            # only with .debug(true)

# or from the GlitchTip side
docker logs axum_glithip-web 2>&1 | grep 'Forbidden'

# does the key in SENTRY_DSN still exist?
docker exec axum_glithip-db psql -U glitchtip -d duck \
  -c "select public_key from projects_projectkey"
```

### Recovery (DSN rotation)

1. Read the current key: `select public_key from projects_projectkey`.
2. Update `SENTRY_DSN` in the backend env (`.env`) —
   `http://<key>@host.docker.internal:9000/1` for the container.
3. `make up-backend` (this is why the split matters — GlitchTip stays up).
4. `curl localhost:3000/api/span`, then
   `make check-glitchtip` — section 5 must show `spanstaging` growing.

## Notes

- `cold-storage-init` is included in `up-glitchtip` because GlitchTip
  `depends_on: service_completed_successfully` on it; starting `glitchtip`
  alone via compose would pull it anyway, but listing it keeps intent clear.
- Never `docker compose down -v` unless a full reset is intended — that
  deletes the DSN keys, staging data, and cold storage in one go.
