---
description: "Apply the loaded configuration to the database structure (/UpdateDBCfg). Explicit only — never implied by /update1cbase"
argumentHint: "[main|extension|all]"
---

# /updatedbcfg — update database configuration

Apply the already-loaded main configuration or extension to the database structure (`/UpdateDBCfg` / `ibcmd infobase config apply`) of the infobase defined in `.dev.env`.

**Explicit invocation only.** Do not run this command because `/update1cbase` just finished, because files were loaded, or because a transfer of changes "usually" needs it. Run it only when:
- the user explicitly asked to update / apply the database configuration (`/UpdateDBCfg`, «обновить конфигурацию БД», `/updatedbcfg`), or
- an orchestrator that owns apply invokes it as a documented step: `/deploy-and-test`, `/restore-testbase`, `/build-release`.

`/update1cbase` never calls this command and never runs `/UpdateDBCfg` itself.

**Target before mode:** follow `content/rules/extension-workspace.md`. Select the current project and exact main/extension target before substituting templates. Do not change `EXTENSION_NAME` or redirect `EXPORT_PATH` in settings to select another extension.

## Select apply scope

- No argument: the target already resolved for this task. Main configuration unless this task's target is one named extension. A stored `EXTENSION_NAME` in `.dev.env` does not by itself select the extension.
- `main`: main configuration (no `-Extension` / `--extension`).
- An explicit extension name, or `extension` when the task target is the extension in `EXTENSION_NAME`: that one extension.
- `all`: main, then every extension from `EXTENSION_NAMES` in list order — see "Full-snapshot mode" below.

This command does not load files from the repository. If the configuration in the infobase is not the intended revision, run `/update1cbase` first (separately), then this command only when apply was requested.

## Step 0. Check `.dev.env` parameters

`.dev.env` is the single source of truth for connection parameters. If it is missing, ask the user to run `install.ps1 init` or copy `.dev.env.example` to `.dev.env`.

Parameters, classes and defaults — `content/rules/dev-standards-env.md §1`; Defaulted keys are never asked for. Keys read: `PLATFORM_PATH`, `INFOBASE_PATH` (**blocking**), `INFOBASE_KIND`, `IB_USER` / `IB_PASSWORD`, `EXTENSION_NAME`, `EXTENSION_NAMES` (`all` mode), `LOG_PATH`, `RESULT_PATH`, `IBCMD_CONFIG`.

**Dev/test gate:** this command forcibly terminates sessions while applying (`--session-terminate=force` / `-SessionTerminate force`). The target must be an explicitly identified dev/test infobase. The gate reads `.dev.env` `INFOBASE_ROLE` (canon `content/rules/dev-standards-env.md → INFOBASE_ROLE`):
- `dev` / `test` — the target is identified; proceed.
- `prod` — do not run Steps 2–3 against it. Hand the user the exact commands with the **production overrides**: no forced termination (`--session-terminate=prompt`, or omit `-SessionTerminate`); an agreed update window; a verified backup first — and stop.
- empty — if the current context does not establish the role, stop before Step 2 and ask the user to confirm the target. Never infer that an arbitrary `.dev.env` points to a test base.

**EDT gate:** when `.dev.env` `USE_EDT=true`, keep **one deployment owner per run**. If EDT already owns `update_database` for this pass, do not also run this command. Canon — `content/rules/edt-workflow.md → DB update, launches, external objects`.

When substituting `.dev.env` values into the templates below, resolve `{INFOBASE_FLAG}` once from the effective `INFOBASE_KIND` (`/F` for `file`, `/S` for `server`; reject any other value), and substitute resolved `{LOG_PATH}` / `{RESULT_PATH}` values that contain `$env:` double-quoted — single quotes do not expand it. Delete a stale `{RESULT_PATH}` file before every Designer launch.

## Step 1. Choose tool: `ibcmd` or Designer

1. Check whether the utility exists: `Test-Path '{PLATFORM_PATH}\bin\ibcmd.exe'`.
2. Check whether `IBCMD_CONFIG` is filled in `.dev.env`.
3. If **both conditions are true**, use **Steps 2a and 3a (`ibcmd`)**.
4. Otherwise use **Steps 2b and 3b (Designer)**.

`ibcmd infobase config` does not apply to 1C cluster infobases; for server cluster infobases always use Designer.

## Step 2. Applicability check — mandatory when an extension is applied

Whenever this run applies an extension (the resolved target is that extension, or an extension pass of `all`), run **ladder steps 1–2** before Step 3 — `/CheckModules` then `/CheckCanApplyConfigurationExtensions` (canon `content/rules/designer-batch-checks.md → The check ladder`, verification contract `content/rules/verification-gates.md → Gate 6`). Same launches as `/update1cbase → Step 2c`. A stored `EXTENSION_NAME` does not make a main apply an extension apply. Read the three-signal verdict after each launch; stop at the first failure and do not run Step 3. Ladder step 4 is this command's Step 3, not a second apply.

When applying through `ibcmd`, this Designer check against the same infobase is still mandatory — `ibcmd` has no applicability check of its own.

For the main configuration alone the ladder is optional — run `/CheckConfig` when the change is large (whole-snapshot deploy, release build) or when the Gate 1–3 MCP validators were not exposed in this session.

## Step 2a / 3a. Update DB structure through `ibcmd` (preferred)

After Step 2 when required:

```powershell
& '{PLATFORM_PATH}\bin\ibcmd.exe' infobase config apply `
    --config='{IBCMD_CONFIG}' `
    --user='{IB_USER}' `
    --password='{IB_PASSWORD}' `
    --force `
    --dynamic=auto `
    --session-terminate=force `
    --extension={EXTENSION_NAME} *>&1 | Tee-Object -FilePath '{LOG_PATH}'
```

Remove empty optional keys (`--user`, `--password`, `--extension`). `--session-terminate=force` is allowed only after the dev/test gate of Step 0.

Continue to **Step 4**.

## Step 2b / 3b. Update DB structure through Designer (fallback)

Map `.dev.env` keys to Designer flags as in `/update1cbase` (`INFOBASE_FLAG`, `/N`, `/P`, `-Extension`).

After Step 2 when required:

```powershell
& '{PLATFORM_PATH}\bin\1cv8.exe' DESIGNER `
    {INFOBASE_FLAG} '{INFOBASE_PATH}' `
    /N '{IB_USER}' `
    /P '{IB_PASSWORD}' `
    /DisableStartupMessages `
    /UpdateDBCfg -Dynamic+ -SessionTerminate force `
    -Extension {EXTENSION_NAME} `
    /Out '{LOG_PATH}' `
    /DumpResult '{RESULT_PATH}'
```

Remove empty optional keys (`/N`, `/P`, `-Extension`). For the main configuration, remove `-Extension {EXTENSION_NAME}` entirely. `-SessionTerminate force` is allowed only after the dev/test gate of Step 0.

Read the verdict: `{RESULT_PATH}` = `0`, exit code `0`, and `{LOG_PATH}` containing `Обновление информационной базы выполнено` / `Database configuration update completed` with no diagnostic lines.

## Apply retry loop — mandatory failure handling for Step 3

Applying rarely succeeds on a dirty state at the first attempt. Handle failures **iteratively**, never by re-running the same command blindly and never by declaring success from the exit code alone.

**1. Log first — after every attempt, success or not.** Read `{LOG_PATH}` in full after each Step 2 / Step 3 run. The platform can write errors to the log while formally exiting 0 (typical: `Ошибка при обновлении конфигурации базы данных`, `Конфигурация не соответствует`). A diagnostic line in the log = failed attempt, regardless of exit code.

**Classify success phrases before error stems** — order and pattern list — `content/rules/designer-batch-checks.md → The success-phrase trap`. Designer templates carry **`/DumpResult '{RESULT_PATH}'`** (three-signal verdict). `ibcmd` returns a reliable exit code and needs no equivalent.

**2. Terminate the Configurator before the next attempt.** Same PID-scoped discipline as `/update1cbase → Load retry loop`: known process handle, timeout, kill only that PID, never blanket-kill `1cv8`.

**3. Fix before retry.** Re-running against an unchanged infobase/configuration is forbidden. Fix the logged cause first. Retrying Step 3 alone after a clean applicability check is fine; after a failed check, fix and re-run Step 2 before Step 3.

**4. Bounded budget — 3 full attempts.** If the third attempt still fails, stop: report the last log fragment, what was fixed between attempts, and the remaining error. Do not present a failed update as done.

## Full-snapshot mode (`/updatedbcfg all`) — optional

Applies the **effective snapshot**: main configuration, then every extension from `EXTENSION_NAMES` (order = apply order). Used by `/restore-testbase`, `/build-release` and `/deploy-and-test` when the user asked to deploy "with extensions".

- If `EXTENSION_NAMES` is empty, resolve inventory via `content/rules/extension-workspace.md`. Confirmed no extensions means a main-only apply; never fall back to `EXTENSION_NAME` for `all`.
- **Pass 1 — main:** Steps 2–3 without `-Extension` / `--extension`.
- **Pass per extension**, in `EXTENSION_NAMES` order: Step 2 (applicability) then Step 3 with `-Extension <Name>` / `--extension=<Name>`.
- A failure stops the mode; report which passes completed and which failed. Each pass has its own 3-attempt retry budget.
- Save each pass's log/result evidence before the next pass reuses those paths.

## Step 4. Final report

Briefly report the infobase, main configuration / extension, tool, checks, apply result, retry attempts, fixes and dynamic update / restructuring from the log. In full-snapshot mode, list every pass. A failed apply remains incomplete; list errors explicitly.

A test client started before this apply is stale (`content/rules/qa-testclient.md`). Behavioural confirmation after a development apply follows the effective `UI_TESTING` policy when the calling orchestrator runs UI checks.
