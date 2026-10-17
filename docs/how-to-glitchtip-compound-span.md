# GlitchTip v6.2.6 — Span Processing and Cold Storage Investigation

## 1. Environment Overview

The current deployment runs GlitchTip v6.2.6 using Docker Compose.

Relevant configuration and services:

- `SERVER_ROLE=all_in_one`
- `GLITCHTIP_EMBED_WORKER=true`
- `GLITCHTIP_ENABLE_DUCKDB=true`
- Valkey is running and responds to `PING` with `PONG`.
- The task backend is configured as `django_vtasks.backends.valkey.ValkeyTaskBackend`.
- The cold storage directory is configured as `/app/glitchtip/cold-storage`.
- The GlitchTip container is running Granian as its ASGI server.
- The container reports `OOMKilled=false`, `ExitCode=0`, and `RestartCount=0`.

The investigation is focused on why Span data remains in PostgreSQL staging and whether the background tasks responsible for Parquet generation are running correctly.

## 2. Confirmed Findings

### PostgreSQL contains Span staging data

The following query was executed successfully:

```sql
SELECT COUNT(*) FROM performance_spanstaging;
```

Result:

```text
Span staging rows: 15
```

This confirms that 15 rows existed in `performance_spanstaging` at the time of the check.

It does not, by itself, prove that all 15 rows are eligible for promotion or that the task processor is failing.

### DuckDB and Parquet functionality

A standalone DuckDB test successfully created and read a Parquet file.

Observed results:

```text
DuckDB version: 1.5.2
File exists: True
File size: 300
Read result: [(123, 'test')]
DUCKDB PARQUET TEST: PASS
```

This confirms that basic DuckDB SQL and Parquet file I/O work inside the container. It does not prove that GlitchTip's background tasks are running or successfully writing production Span files.

The GlitchTip v6.2.6 source indicates that Span Parquet writes use `arro3`, while DuckDB is used for querying cold storage. Therefore, the standalone DuckDB write test should not be treated as a complete test of GlitchTip's Span promotion pipeline.

### Valkey is reachable

The command:

```bash
docker compose exec valkey valkey-cli ping
```

returned:

```text
PONG
```

Valkey is responding to requests now. This does not prove that it was ready when GlitchTip started, nor does it prove that queued tasks are being consumed.

### Embedded worker configuration is enabled

The environment of the actual Granian process was inspected through `/proc/1/environ`.

Results:

```text
GLITCHTIP_ENABLE_DUCKDB=true
SERVER_ROLE=all_in_one
GLITCHTIP_EMBED_WORKER=true
```

This confirms that the actual server process has the expected environment variables.

### Task backend and schedules

The effective Django configuration reports:

```text
DUCKDB: true

VTASKS_SCHEDULE:
{
  'promote-spans': {
    'task': 'apps.performance.tasks.promote_spans',
    'schedule': 300
  },
  'compact-span-chunks': {
    'task': 'apps.performance.tasks.compact_span_chunks',
    'schedule': 900
  }
}

TASK BACKEND:
django_vtasks.backends.valkey.ValkeyTaskBackend
```

The schedules are configured as follows:

- `promote-spans`: every 300 seconds (5 minutes).
- `compact-span-chunks`: every 900 seconds (15 minutes).

These settings establish that the tasks are configured, but not that they have been executed successfully.

## 3. Span Processing Architecture

The source code inspection identified these files:

```text
/code/apps/performance/promotion.py
/code/apps/performance/tasks.py
/code/glitchtip/asgi.py
/code/glitchtip/settings.py
/code/glitchtip/task_signals.py
```

The processing flow is expected to be:

1. The Rust application sends transactions and spans to GlitchTip.
2. GlitchTip ingests the data and stores staging records in PostgreSQL.
3. The `promote_spans` background task selects eligible staging rows.
4. The promotion function groups records by organization and date, writes Parquet chunks, and deletes consumed staging rows.
5. The `compact_span_chunks` task processes sealed chunks for cold storage.
6. DuckDB is used to query cold storage.

The exact task execution status still needs to be verified.

## 4. Important Source Code Findings

### `apps/performance/tasks.py`

The task module contains:

```python
@task
async def promote_spans():
    promoted, truncated = await _promote_spans()
    if truncated and promoted > 0:
        logger.info(
            "Promotion batch full (%d rows), re-enqueueing",
            promoted,
        )
        await promote_spans.aenqueue()
```

It also contains:

```python
@task
async def compact_span_chunks():
    await sync_to_async(_compact_span_chunks)()
```

This establishes that both functions are registered as background tasks through `django_vtasks`.

### `apps/performance/promotion.py`

The promotion function includes these conditions:

```python
if not is_duckdb_available():
    logger.debug("DuckDB not available, skipping span promotion")
    return 0, False

storage = get_cold_storage_backend()
if not storage:
    logger.debug("No storage backend, skipping span promotion")
    return 0, False
```

The function uses a five-minute cutoff:

```python
cutoff = now_dt - timedelta(minutes=5)
```

Only eligible staging records older than that cutoff are considered for promotion.

Consequently, staging rows may remain in PostgreSQL if they are too recent, if no storage backend is available, or if the promotion task is not executing successfully.

### `glitchtip/settings.py`

When `GLITCHTIP_ENABLE_DUCKDB=true`, the following scheduled tasks are registered:

```python
VTASKS_SCHEDULE["promote-spans"] = {
    "task": "apps.performance.tasks.promote_spans",
    "schedule": 300,
}

VTASKS_SCHEDULE["compact-span-chunks"] = {
    "task": "apps.performance.tasks.compact_span_chunks",
    "schedule": 15 * 60,
}
```

The default task backend is `DatabaseTaskBackend`, but when `VALKEY_URL` is configured, GlitchTip switches to `ValkeyTaskBackend`.

The effective configuration in this deployment is `ValkeyTaskBackend`.

### `glitchtip/asgi.py`

The application checks:

```python
_embed_worker = (
    os.environ.get("GLITCHTIP_EMBED_WORKER") == "true"
)
```

When enabled, it wraps the ASGI application using:

```python
from django_vtasks.asgi import get_worker_application

application = get_worker_application(application)
```

The installed `django_vtasks.asgi.get_worker_application()` implementation creates a worker during ASGI lifespan startup. It also attempts to start the scheduler if `settings.VTASKS_RUN_SCHEDULER` is enabled and the schedule is non-empty.

If startup fails, the implementation logs:

```text
Worker/Scheduler startup failed
```

The application therefore depends on successful ASGI lifespan startup for the embedded worker and scheduler to run.

## 5. Current Unresolved Issue

A diagnostic command attempted to access:

```python
settings.VTASKS_RUN_SCHEDULER
```

It failed with:

```text
AttributeError: 'Settings' object has no attribute
'VTASKS_RUN_SCHEDULER'
```

This is an important discrepancy because the installed `django_vtasks.asgi` implementation references that setting.

However, the exception occurred in a separate diagnostic Django shell process. It does not establish that the production Granian process encountered the same error during ASGI startup.

The next step is to inspect the installed `django_vtasks` package to determine where `VTASKS_RUN_SCHEDULER` is defined, whether it has a default, and whether the package and GlitchTip configuration are compatible.

## 6. What Has Not Been Proven

The following points remain unverified:

- Whether the ASGI lifespan startup successfully started the embedded worker.
- Whether the scheduler started successfully.
- Whether `promote_spans` has been enqueued or executed.
- Whether `compact_span_chunks` has been enqueued or executed.
- Whether eligible staging records are older than the five-minute cutoff.
- Whether `get_cold_storage_backend()` returns a valid storage backend.
- Whether the task queue contains pending or failed tasks.
- Whether any production Span Parquet files have been generated successfully.

The absence of a task-related message in the filtered logs is not conclusive proof that the scheduler is not running.

## 7. Recommended Next Steps

### Step 1: Inspect the installed `django_vtasks` package

Run:

```bash
docker compose exec glitchtip python manage.py shell -c '
import os
import django_vtasks

root = os.path.dirname(django_vtasks.__file__)
print("Package path:", root)

for base, _, files in os.walk(root):
    for filename in files:
        if filename.endswith(".py"):
            path = os.path.join(base, filename)
            try:
                with open(path) as f:
                    for n, line in enumerate(f, 1):
                        if "VTASKS_RUN_SCHEDULER" in line:
                            print(f"{path}:{n}: {line.strip()}")
            except OSError:
                pass
'
```

This should clarify where the missing setting is expected to come from.

### Step 2: Check actual scheduler startup logs

Run:

```bash
docker compose logs --since=2h glitchtip 2>&1 \
  | grep -iE \
'local scheduler lock|worker/scheduler startup failed|stopping embedded worker|promote.spans|compact.span|task_failure|task_finished' \
  | tail -100
```

Look for scheduler startup, task execution, task failures, and shutdown messages.

### Step 3: Inspect the cold storage backend

Inspect the implementation of `get_cold_storage_backend()` and confirm that the configured storage directory exists and is writable by the application process.

### Step 4: Inspect task queue status

Use the actual task backend implementation and its supported APIs to inspect queued, running, or failed tasks. Avoid guessing Valkey key names or manipulating queue contents before understanding the installed backend.

### Step 5: Recheck staging and generated files

After the worker and scheduler status are established, check:

```sql
SELECT COUNT(*) FROM performance_spanstaging;
```

Also check for Parquet files under the configured cold storage directory.

Compare the results over time to determine whether eligible records are being promoted.

## 8. Current Conclusion

The investigation has established that Span staging data exists, DuckDB works in a standalone test, Valkey is reachable, the actual Granian process has embedded-worker configuration enabled, and both Span tasks are registered in the schedule.

The primary remaining question is whether the embedded worker and scheduler are successfully starting and executing tasks in the running GlitchTip instance.

The missing `VTASKS_RUN_SCHEDULER` setting is a concrete issue to investigate, but it should not yet be declared the root cause. The next step is to inspect the installed `django_vtasks` package and confirm actual task execution before changing the configuration or restarting services.
