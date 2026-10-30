# AAP 2.6 live-integration scenario

This is a standalone, repeatable evaluation scenario for the experimental
driver. It is a test plan, not a record of a successful test. It has not been
run by the plugin's automated suite and makes no production-readiness claim.
Run it only against disposable or dedicated non-production Foreman, Git, AAP,
inventory, and managed-host resources.

The complete setup contract and limitations are in
[Experimental AAP execution driver](experimental-aap.md). Satisfy that guide
before starting this scenario.

## Evidence directory and required variables

Create an evidence directory outside the generated-playbook repository. Never
store tokens, passwords, rendered secret material, or private keys in it.
Record the Foreman, plugin, AAP 2.6, Git server, and execution-environment
versions.

The repository includes `script/aap-live-evidence`, a read-only AAP API helper.
It requires `bash`, `curl`, and `jq`. Export values in the shell rather than
putting the service token on a command line:

```sh
export AAP_CONTROLLER_URL='https://aap.example.test/api/controller/v2/'
export AAP_SERVICE_TOKEN='<dedicated-validation-token>'
export AAP_JOB_TEMPLATE_ID='7'
export AAP_PROJECT_ID='9'
export AAP_INVENTORY_ID='8'
export AAP_JOB_ID='91'
export AAP_CA_BUNDLE='/path/to/private-ca.pem' # omit for public trust
export AAP_EVIDENCE_DIR='/path/to/evidence/baseline-job-91'
script/aap-live-evidence
```

The helper saves the configured resources, job, all event pages, and all
job-host-summary pages. It does not launch, cancel, or modify AAP resources.
Unset `AAP_SERVICE_TOKEN` after each collection. Protect the evidence directory
because job output may still contain environment-specific data.

For every phase, record start/end timestamps, Foreman Job Invocation ID and
task ID, generated ref and commit, AAP job ID, Project and inventory update job
IDs, exact launch limit, job status, per-host Foreman result, page counts,
event counts, and observed errors. Preserve server logs around injected
failures without copying credentials.

## Test topology and template

Use at least these canonical Foreman host names:

- `ok-a.example.test` and `ok-b.example.test`, reachable and expected to pass;
- `fail.example.test`, reachable but made to fail one explicit task;
- `unreachable.example.test`, present in inventory but deliberately
  unreachable using a validation-only credential or network rule;
- `missing.example.test`, present in Foreman but intentionally absent from the
  synchronized AAP inventory; and
- one prepared original host whose playbook contains a delegated task to a
  controlled validation endpoint.

The names of inventory members must exactly match Foreman `host.name`. Keep an
additional inventory member outside every Foreman target to detect accidental
host-set expansion.

Create a dedicated Foreman Ansible Job Template that contains no Foreman host
macros and no secrets. It should:

1. emit a recognizable line before and after a delay long enough to inspect
   live output and restart Foreman safely;
2. succeed on the two `ok-*` hosts;
3. fail explicitly only on `fail.example.test`;
4. run a harmless delegated task while preserving the original inventory host
   in AAP event data; and
5. leave credentials, privilege escalation, and the execution environment to
   the fixed AAP Job Template.

Use a validation-only Foreman user and scoped roles to induce a local
per-host authorization failure without changing the template. Confirm that the
user can create the overall invocation and prepare the permitted hosts while
one selected host fails the plugin's local preparation checks. Prepare a
second target set containing only locally disallowed hosts for the zero-host
case.

## Phase 1: fixed-resource preflight

1. Keep `ansible_execution_driver` set to `proxy`.
2. Confirm the Project SCM URL exactly equals `aap_repository_url`, and confirm
   Project update-on-launch is enabled.
3. Confirm at least one dynamic inventory source has inventory
   update-on-launch enabled and completes a fresh synchronization.
4. Confirm the fixed Job Template selects the configured Project, inventory,
   and generated playbook path. Confirm SCM branch, limit, and variables are
   all promptable. Confirm its execution environment and machine credentials
   are AAP-owned.
5. Use the service token to inspect only those resources, launch the fixed
   template in a disposable dry-run if appropriate, cancel its job, and read
   its job, events, and summaries. Reduce permissions if unrelated resources
   are visible or executable.
6. Verify Foreman's Git write credential cannot authenticate to AAP and the AAP
   Project read credential cannot push to the repository.
7. Change `ansible_execution_driver` to `aap` only after these checks pass.

Expected observations: no AAP-specific work occurs while proxy is selected;
the fixed resources satisfy preflight; TLS peer verification succeeds; and the
service account has no general administrative or arbitrary-template launch
permission.

## Phase 2: baseline multi-host execution

1. Target `ok-a.example.test` and `ok-b.example.test` in one Foreman Job
   Invocation.
2. While it runs, poll Foreman's normal per-host output endpoint or watch the
   Job Invocation page. Record when the first and last AAP lines appear.
3. In AAP, record the Project update-on-launch and inventory update-on-launch
   prerequisite jobs, then the single playbook job.
4. Collect AAP evidence with `script/aap-live-evidence` after setting the
   returned `AAP_JOB_ID`.
5. Inspect the dedicated Git remote with read-only `git ls-remote` and `git
   show`. Do not check out credentials into the evidence directory.

Expected observations:

- there is one hostless render, one immutable
  `foreman/<instance-id>/job-invocation-<id>` ref, and exactly one AAP playbook
  job;
- AAP completes its Project update-on-launch and inventory update-on-launch
  prerequisites before executing the invocation-specific content;
- the AAP launch has the exact primary-host limit
  `ok-a.example.test,ok-b.example.test` and only the two correlation variables;
- both hosts use the AAP-owned execution environment and machine credential;
- native structured job events appear as live per-host Foreman output; and
- native job-host summaries settle both Foreman host tasks successfully.

Also record rendered payload bytes, target count, Project and inventory
synchronization latency, playbook-job latency, event page size/count, summary
page size/count, and time-to-first-output.

## Phase 3: preparation boundaries

Run an invocation containing permitted hosts plus the host denied by the
validation user's scoped Foreman permissions. Then run the target set in which
every host is locally denied.

Expected observations: a partial preparation failure remains attached to its
host task while the successfully prepared subset produces one ref and one AAP
job with an exact reduced limit. With zero prepared hosts, Foreman creates no
Git ref, performs no AAP preflight, and launches no AAP job.

## Phase 4: identity and mixed outcomes

Run one invocation targeting the two passing hosts, the explicit failure, the
unreachable host, and the missing inventory host. Include the harmless
delegated task. Keep an unrelated extra inventory member outside the limit.

Expected observations:

- mixed host outcomes preserve successes while failed and unreachable
  summaries fail only their matching Foreman hosts;
- `missing.example.test` receives no summary and fails with the missing
  inventory host diagnostic;
- the unrelated inventory member never becomes a Foreman result, even if AAP
  exposes an extra summary or event;
- the delegated task output is attributed to the original prepared inventory
  host when AAP supplies `event_data.host`; and
- unassociated events become invocation diagnostics rather than new host
  tasks.

Record the precise AAP event and job-host-summary payloads for the failed,
unreachable, missing, extra-summary, and delegated-task cases. If AAP cannot
naturally produce an extra summary under an exact limit, record that fact and
exercise the extra-summary boundary with a captured-payload replay or fault
adapter; do not claim it was observed live.

## Phase 5: polling restart and pagination

Use enough output to cross at least two AAP event pages. During the deliberate
delay, restart Foreman and its Dynflow worker with the platform's supported
service command. Do not restart AAP or change the fixed resources.

Expected observations: polling resumes for the persisted AAP job; Foreman's
per-host output has no lost or duplicated lines; event identities remain
unique; all pages and the final terminal catch-up are consumed; and final host
results come from summaries. Record the restart interval and compare ordered
AAP event IDs with Foreman Template Invocation external IDs.

## Phase 6: failed-host rerun

From the mixed invocation, use Foreman's failed-host rerun workflow.

Expected observations: the failed-host rerun creates a new Job Invocation, a
fresh immutable ref and commit, and one new AAP job. Its exact primary-host
limit contains only the hosts selected by Foreman's rerun semantics. The
original invocation, ref, job, output, and outcomes remain unchanged.

## Phase 7: whole-job cancellation

Run the template with one host able to finish before another long-running
host. Request whole-job cancellation in Foreman after the first summary can be
observed. Separately attempt host-filtered cancellation through both supported
Foreman UI/API entry points without confirming a destructive request.

Expected observations: whole-job cancellation sends one AAP cancellation
request, Foreman continues polling until terminal state, completed host
outcomes remain intact, and unfinished hosts become cancelled. Host-filtered
cancellation is rejected clearly and does not cancel the aggregate job.

## Phase 8: safety and failure injection

Perform each mutation only on validation resources and restore it afterward:

- Pre-create the next deterministic Git ref with different generated content;
  verify the conflict fails without force-push or deletion. Repeat with
  identical content to exercise idempotent acceptance where practical.
- Disable one prompt-on-launch field, then restore it. Verify preflight or
  launch-response checking prevents unsafe execution and an ignored launch
  field triggers a cancellation request.
- Temporarily introduce AAP 429/5xx or network failures while polling. Verify
  bounded retries and recovery without another launch.
- Revoke read authorization or make the persisted job return 404. Verify a
  permanent observation failure settles unfinished hosts with an integration
  diagnostic.
- Use a boundary fault injector that lets AAP accept a launch but drops the
  response before Foreman can persist the job ID. Verify the ambiguous launch
  failure says AAP might still be executing, performs no automatic retry or
  correlation search, and requires an operator to inspect AAP.

Do not simulate an ambiguous launch merely by making AAP reject the request;
that is a definitive failure and does not test the ambiguity window. If a
boundary case cannot be produced safely, record it as unvalidated and use a
captured-response adapter without describing the result as live behavior.

## Validation report and exit rule

Write a report containing:

- all versions and non-secret resource coordinates;
- the evidence identifiers and timestamps for every phase;
- payload and target scale, sync and execution latency, pagination behavior,
  restart interval, and cancellation timing;
- the exact observed behavior for Git conflicts, ignored fields, transient and
  permanent observation failures, and ambiguous launch;
- every divergence from the setup contract or expected observations;
- operational limitations and risks that remain; and
- an explicit list of architectural assumptions that were not tested.

Do not mark the POC production-ready because this scenario completed. Every
architectural assumption must be validated, every divergence must be resolved,
and remaining risks must be explicitly accepted in a follow-up production
design.
