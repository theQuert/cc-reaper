# Reclaim abandoned host temp every hour

## Why

On 2026-09-30 the reporting host fell to 41.7 GB free (9%). Four producers the janitor did not reach, or reached only weekly, held most of it:

- A session's headless-Chrome scripts create a `cdp-XXXXXX` profile in the user's temp directory on every run and never remove it. When a script dies before `chrome.kill()`, the browser is left running, reparented to launchd, with nothing connected. There were 137 profiles (10.1 GB) and six such browsers, the oldest running for 30 hours.
- Wrangler writes one debug log per `wrangler pages dev` run, up to 575 MB each, and never removes them. There were 281 logs (5.1 GB).
- Docker builder cache grew 24.7 GB in two days, while the weekly prune only reaches cache unused for 168 hours.
- Chrome code-sign clones reached 212, because the clone janitor keeps anything under three days old. APFS shares their blocks, so they cost little space, but the count grows by about 100 a day.

Removing all of these by hand on 2026-10-01 took the host from 41.7 GB free to 75 GB free, and it stopped no session and no build. That removal is what this change automates.

## What Changes

- The hourly `--check` runs `host-temp-reaper.py clean`. It removes only items proved abandoned:
  - **An orphaned headless Chrome** gets `SIGTERM`, and only if all of these hold:
    - it is the browser binary, never a Helper;
    - it runs `--headless` with `--remote-debugging-port`;
    - its `--user-data-dir` is directly under the temp directory;
    - its parent is launchd;
    - it has run for the idle limit;
    - no DevTools client is connected to any port it listens on.

    The pid is rechecked right before the signal.
  - **A `cdp-XXXXXX` profile** is removed when no running process names it as its `--user-data-dir`, no process holds it open, and it has not changed for the idle limit.
  - **A `wrangler-*.log`** is removed when nothing has written it for the idle limit and no process holds it open.
  - Any probe that fails or cannot decide keeps the item. The idle limit is `CC_DJ_HOST_TEMP_IDLE_MINUTES` (default 60, minimum 30), and `CC_DJ_HOST_TEMP_REAP=0` turns the step off.
- The hourly `--check` removes unheld Chrome code-sign clones older than `CC_DJ_CHROME_CLONE_MIN_AGE_DAYS` (default 1). The weekly clean uses the same age.
- Once a day, the hourly `--check` runs `docker builder prune --force --filter until=24h`. The filter is `CC_DJ_BUILDER_PRUNE_UNTIL`, and `off` turns the prune off. BuildKit never prunes a record a running build holds. The weekly 168h prune is unchanged.
- The hourly check is therefore no longer read-only. It still never removes images, containers, volumes or anything outside these exact names.
