# Lab 15 human acceptance

All human acceptance results are **PENDING**. Record PASS, FAIL or BLOCKED only after executing each case. Local script or syntax checks do not establish a successful GitHub Actions run.

## Prerequisites and local verification

Use PowerShell 7.5+, Docker with Linux containers, and Docker Compose supporting `!reset` and `!override`. Image registries, NuGet and Ubuntu/ROS package repositories must be reachable. Allow capacity for SQL Server, Kafka, the ROS nodes, monitoring, Jaeger and image builds. A host .NET SDK is optional.

From Windows PowerShell 7, run the commands below. On Linux, replace the first command with the checkout directory.

```powershell
Set-Location C:\Dev\Demo_Project
$PSVersionTable.PSVersion
docker version
docker compose version
pwsh -NoProfile -File ./tests/lab14-acceptance.ps1
$acceptanceExit = $LASTEXITCODE
Get-Content ./TestResults/lab14/summary.json -Raw
Get-Content ./TestResults/lab14/report.md
if ($acceptanceExit -ne 0) { throw "Acceptance failed with exit $acceptanceExit" }
git diff --check
```

Expected acceptance exit code is 0 with twelve PASS checkpoints and four nonempty alert/SLO/trace evidence files. A missing prerequisite must produce a nonzero exit code. Keep outputs under Git-ignored `TestResults`.

## Trigger and inspect CI

After human review and an authorized commit/push, push a branch or open a pull request to trigger `Lab 15 Acceptance`. For manual execution, first make the workflow available on the default branch, then open **Actions → Lab 15 Acceptance → Run workflow** and choose the branch. No repository secrets are required. Fork pull requests may require a maintainer to approve execution.

The single job is **Full system acceptance** on `ubuntu-24.04`, with a 45-minute timeout. Expect checkout, prerequisite and quiet Compose validation, the Lab 14 suite, report validation, scoped cleanup and artifact upload. The suite builds containers and applies migrations inside its isolated project. It checks the entire receipt round trip, dependency health, offset safety, SQL recovery and consumer restart, dashboards, alerting, SLO and tracing.

Prerequisite or required-test failures must make the job fail. Report validation runs even after a failed acceptance step and rejects absent/empty reports, a failed or incomplete checkpoint set, or missing evidence. Upload and cleanup use `always()` and do not convert earlier failures to success.

Download `lab15-acceptance-<run_id>-<run_attempt>` from the workflow run's **Artifacts** section within seven days. Inspect `lab14/summary.json`, `lab14/report.md`, `lab15/preflight.txt`, and the project-specific alert JSONL, SLO JSONL and both Jaeger trace JSON files. The upload uses `TestResults` as its common root. Paths inside reports describe the runner checkout. Match filenames in the downloaded archive. Failed runs can have partial evidence. Inspect the original failed step in the Actions log for command details. Artifacts intentionally exclude `.env`, Docker inspection output, raw service logs and console transcripts.

## Controlled negative case and restoration

Use a disposable branch and pull request, with human approval for any commit/push. Change only the expected consumer group offset assertion in `tests/lab8-receipts.ps1` immediately after `consumer halt on SQL outage`, from `Assert-Group 3 5 2` to `Assert-Group 3 5 999`. This changes a test expectation for the isolated stack. The existing checks and cleanup remain active.

1. Run Lab 14 locally. Expect a timeout waiting for the impossible lag, a nonzero exit code, a FAIL summary, and subsequent SKIP checks. Cleanup should still run.
2. Push the disposable branch after review and inspect its PR workflow. Confirm **Run Lab 14 acceptance** fails, **Validate acceptance reports** rejects the failed summary, and artifact upload is attempted. Record both the original failure and the final job conclusion.
3. Download artifacts. Confirm diagnostics identify the failed test location, partial results are retained, and generated test credentials are absent. For the independent missing-report gate, download a successful run's artifacts into `TestResults` inside a temporary directory, remove only that copy's `TestResults/lab14/report.md`, and execute the **Validate acceptance reports** PowerShell block from the workflow in that temporary directory using a new `pwsh -NoProfile -File` process. Expect an exception and a nonzero process exit. This checks the report gate without changing acceptance execution.
4. Restore the assertion to `Assert-Group 3 5 2`, inspect `git diff`, and rerun the same PR workflow after an authorized update. Expect all twelve checkpoints and the job to pass. Close the disposable PR after recording results.

To inspect retained test resources, obtain `composeProject` from the summary or read `TestResults/lab14/compose-project.txt`. Both identify the same generated project. The suite normally removes its containers and network in `finally`; CI also attempts cleanup from the startup marker if the suite was interrupted. On a local host, restore any required test-only password environment variable and use the exact project value with the command below only if its containers remain.

```powershell
$project = (Get-Content ./TestResults/lab14/compose-project.txt -Raw).Trim()
if ($project -cnotmatch '^fleet-lab8-check-[0-9a-f]{8}$') { throw 'Unexpected cleanup project' }
$env:MSSQL_SA_PASSWORD = 'CleanupOnly!' + [guid]::NewGuid().ToString('N')
docker compose --profile lab7 --profile monitoring -f compose.yaml -f tests/lab4.compose.yaml -p $project down --timeout 10
Remove-Item Env:MSSQL_SA_PASSWORD
```

Use a fresh terminal for this cleanup example so a previously configured password is preserved in its original shell. Named volumes remain intact. Hard runner termination can prevent final steps. GitHub disposes hosted runner VMs after the job.

## Required status check and merge blocking

Repository administrators must approve and configure this manually. After the check has run, open **Settings → Rules → Rulesets** or the repository's branch protection controls. Target `main`, require pull requests and status checks, and select the observed GitHub Actions check **Full system acceptance** from `Lab 15 Acceptance`. Use the exact check name shown by GitHub. Keep the job name stable. Apply the rule without an actor bypass for the account used to verify merge blocking.

On the disposable failing PR, confirm the required check is red and merging is blocked. Record the UI evidence and the active rule. Restore the assertion and verify the rerun succeeds and the required-check blocker clears. GitHub plan and repository visibility affect protection availability. A workflow file alone does not enable branch protection. See [required status checks](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## Human result record

| Case | Expected result | Actual result | Evidence | PASS / FAIL / BLOCKED |
|---|---|---|---|---|
| Local full acceptance | Exit 0, twelve PASS checks | PENDING | PENDING | PENDING |
| Hosted Ubuntu full acceptance | Successful job | PENDING | Run URL pending | PENDING |
| Artifact contents | Reports and four evidence files, no credentials | PENDING | Artifact pending | PENDING |
| Controlled required-test failure | Nonzero exit, failed job, partial evidence | PENDING | Run URL pending | PENDING |
| Missing prerequisite | Failure before acceptance can pass | PENDING | Step log pending | PENDING |
| Missing report gate | Nonzero process exit | PENDING | Local gate output pending | PENDING |
| Scoped cleanup | Only generated project cleaned, volumes retained | PENDING | Project evidence pending | PENDING |
| Required check blocks merging | Failing PR cannot merge under active rule | PENDING | Rule and PR evidence pending | PENDING |
| Restoration | Successful rerun clears required-check blocker | PENDING | Run and PR URLs pending | PENDING |

## Known limits

Hosted Linux execution and resource capacity require an actual workflow run. The full stack plus cold builds can exceed standard-runner memory or disk capacity. The workflow prints resource information and fails on missing prerequisites rather than reducing coverage. Registry outages, ROS discovery timing, job cancellation and the 45-minute timeout can prevent completion. Preserve the partial evidence and original step failure when diagnosing these cases.
