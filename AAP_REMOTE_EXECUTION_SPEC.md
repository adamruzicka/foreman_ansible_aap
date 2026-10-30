# AAP-backed Ansible Remote Execution

## Problem Statement

Foreman currently executes Ansible remote execution jobs through Smart Proxies. The execution model creates and renders work per host, prepares hosts in chunks, delegates work to proxies, and observes proxy tasks. This does not match Ansible Automation Platform (AAP), where one job can execute one playbook against a filtered inventory at substantially greater scale.

Administrators need to select AAP as the global backend for Ansible remote execution while retaining Foreman as the user-facing source of authorization, targeting intent, progress, output, results, reruns, cancellation, and audit history. A Foreman Job Invocation must map to at most one AAP playbook job, while still preserving host-specific preparation failures and execution results.

Foreman cannot rely on static, SCM-authored playbooks because its Job Templates are rendered for each invocation. The rendered playbook must therefore be published as an immutable artifact that AAP can execute through its native Project and Job Template model.

## Solution

Add an optional `foreman_ansible_aap` plugin that registers an experimental, globally selected AAP driver for the existing Ansible provider. The public provider remains `Ansible`; existing Job Templates do not acquire a separate AAP provider type. The driver is locked onto each Job Invocation when that invocation is created, and existing proxy execution remains the default.

The module ownership is deliberately split. `foreman_remote_execution` provides a narrow sanctioned seam for selecting the top-level execution action. `foreman_ansible` owns the Ansible provider, Job Templates, default proxy adapter, and driver registry. `foreman_ansible_aap` depends on both plugins, registers the AAP adapter, and owns all AAP-specific settings and implementation. The new plugin must not rely on load-order-sensitive monkeypatches of REX or `foreman_ansible` internals.

In AAP mode, Foreman plans all lightweight per-host tasks up front. Each task retains responsibility for host-specific permission checks, local preparation, observable preparation failures, and its eventual result. Successfully prepared hosts are handed to one aggregate AAP action. The aggregate action renders the Foreman Job Template once without a current-host context, publishes the rendered playbook to a deterministic immutable Git ref, launches one fixed AAP Job Template against the successfully prepared hosts, polls AAP, streams events back into per-host Template Invocations, and settles the per-host tasks from final AAP host summaries.

The generated Git ref is based on an administrator-configured base ref and places the rendered playbook at a fixed path. The AAP Project uses the dedicated repository, permits branch override, and updates on launch. The AAP Job Template uses that fixed playbook path and a fixed Foreman-synchronized dynamic inventory. AAP owns execution credentials, execution environment, capacity, parallelism, and timeout.

Foreman only creates immutable refs. Repository initialization, access policy, retention, cleanup, and maintenance remain administrator responsibilities.

## User Stories

1. As a Foreman administrator, I want to select either Smart Proxy or AAP as the global Ansible driver, so that one Foreman installation has a predictable Ansible execution model.
2. As a Foreman administrator, I want proxy execution to remain the default after installation or upgrade, so that enabling the experimental driver is explicit.
3. As a Foreman user, I want each Job Invocation to retain the driver selected when it was created, so that a later settings change cannot alter an in-progress job.
4. As a scheduler user, I want each recurring occurrence to be a distinct Job Invocation that reads the current global driver, so that future occurrences follow current configuration.
5. As a Foreman user, I want one Foreman Job Invocation to launch at most one AAP playbook job, so that execution and audit history have a clear one-to-one relationship.
6. As an AAP administrator, I want AAP-created Project and inventory synchronization jobs to remain internal prerequisites, so that update-on-launch does not violate the one-playbook-job contract.
7. As a Foreman user, I want all target hosts prepared up front without Foreman-side batching, so that AAP controls execution scale and parallelism.
8. As a Foreman user, I want host permission and preparation failures attached to the affected host task, so that failures remain easy to diagnose.
9. As a Foreman user, I want successfully prepared hosts to proceed when other hosts fail preparation, so that one bad host does not block the full invocation.
10. As a Foreman user, I want an invocation with no successfully prepared hosts to finish locally, so that Foreman does not publish or launch empty work.
11. As a template author, I want the Job Template rendered once per Job Invocation, so that rendering cost does not grow with host count.
12. As a template author, I want AAP-backed rendering to have no implicit current host, so that a single playbook cannot silently depend on target ordering.
13. As a template author, I want invocation-level inputs resolved once, so that the rendered playbook has one deterministic set of inputs.
14. As a template author, I want host-specific runtime data to come from AAP inventory variables and Ansible facts, so that one playbook can operate across the complete target set.
15. As a template author, I want roles, collections, and relative assets from the configured base Project to remain usable, so that shared automation content does not have to be embedded into the rendered file.
16. As a template author, I want missing relative assets to fail naturally in AAP, so that the POC does not need a second playbook validator.
17. As a security administrator, I want rendered playbooks to be secret-free, so that secrets are not committed to Git or retained in AAP job artifacts.
18. As an AAP administrator, I want machine credentials, vault credentials, privilege escalation, and execution environment configuration to remain in AAP, so that AAP stays the execution credential boundary.
19. As a repository administrator, I want generated playbooks written only to a dedicated repository, so that machine-generated execution artifacts are isolated from human-authored repositories.
20. As a repository administrator, I want Foreman to create only deterministic immutable refs, so that it never rewrites or deletes repository history.
21. As a repository administrator, I want repository initialization, permissions, retention, and cleanup to remain external to Foreman, so that Foreman does not become a Git repository manager.
22. As a Foreman operator, I want each generated ref namespaced by Foreman instance and Job Invocation, so that multiple installations can share a repository without accidental collisions.
23. As a Foreman operator, I want a conflicting existing ref with different content to fail safely, so that collision or tampering is not hidden.
24. As a Foreman operator, I want an existing deterministic ref with matching content to be reusable after an ambiguous Git push, so that publication is retryable without mutation.
25. As an auditor, I want Foreman to retain the generated ref and commit SHA, so that an invocation can be correlated with its exact playbook artifact.
26. As an AAP administrator, I want one fixed Job Template and fixed inventory, so that Foreman cannot select arbitrary AAP execution resources at launch.
27. As an AAP administrator, I want Foreman to override only the SCM ref, exact host limit, and correlation metadata, so that launch-time authority is narrowly scoped.
28. As an AAP administrator, I want the Project and inventory source to update on launch, so that synchronization remains owned by AAP.
29. As a Foreman administrator, I want runtime preflight to validate the configured Job Template, Project, repository URL, inventory, playbook path, and prompt settings before publication, so that unsafe launches fail early.
30. As a Foreman administrator, I want Foreman to verify AAP TLS certificates, so that execution intent and output are not exposed to an untrusted endpoint.
31. As a Foreman administrator, I want a dedicated encrypted AAP service token, so that the POC does not depend on individual user credentials.
32. As a Foreman administrator, I want separate encrypted Git and AAP credentials, so that push and execution permissions remain independent.
33. As an AAP administrator, I want the Foreman service account to require only read access to configured resources plus launch, cancel, and job-observation permissions, so that administrator access is unnecessary.
34. As a Foreman user, I want the AAP launch limited to the exact prepared inventory host names, so that the primary play host set matches Foreman targeting.
35. As a playbook author, I want trusted playbooks to retain normal Ansible delegation behavior, so that tasks can deliberately delegate outside the primary play host set.
36. As a Foreman user, I want delegated task results attributed to the original inventory host where AAP reports that relationship, so that host results follow Ansible recap semantics.
37. As a Foreman user, I want unassociated AAP events retained as invocation-level diagnostics, so that useful output is not lost or incorrectly attached to a Foreman host.
38. As a Foreman user, I want live AAP events visible through the existing per-host output model, so that long-running jobs remain observable.
39. As a Foreman user, I want repeated polling to deduplicate events and consume every page, so that output is neither repeated nor lost.
40. As a Foreman user, I want a final event catch-up after AAP becomes terminal, so that late events are captured.
41. As a Foreman user, I want final per-host outcomes derived from AAP host summaries, so that unreachable, failed, successful, rescued, and skipped work is represented accurately.
42. As a Foreman user, I want prepared hosts missing from AAP host summaries to fail, so that stale inventory cannot produce false success.
43. As a Foreman user, I want successful hosts preserved when the aggregate AAP job fails, so that partial success and failed-host reruns remain useful.
44. As a Foreman user, I want a host summary failure to override an aggregate successful status, so that per-host failure is not hidden.
45. As a Foreman user, I want completed host outcomes preserved after cancellation, so that cancellation does not erase work already observed.
46. As a Foreman user, I want failed-host reruns to create a new Job Invocation, render a new artifact, and launch a new AAP job for only the failed hosts, so that reruns remain independently auditable.
47. As a Foreman user, I want whole-job cancellation to issue one AAP cancellation request and continue polling until terminal state, so that accepted cancellation is not confused with completed cancellation.
48. As a Foreman user, I want host-filtered cancellation rejected in AAP mode, so that a host-level request cannot unexpectedly cancel the entire AAP job.
49. As a Foreman user, I want transient AAP polling failures retried with bounded exponential backoff, so that temporary loss of connectivity does not change execution outcomes.
50. As a Foreman user, I want permanent AAP observation failures to fail unfinished hosts with an integration diagnostic, so that jobs do not remain pending indefinitely.
51. As a Foreman operator, I want an ambiguous AAP launch to fail without an automatic retry, so that Foreman does not knowingly create duplicate AAP jobs.
52. As a Foreman operator, I want ambiguous launch errors to warn that AAP might still be executing, so that hard failure does not create false operational certainty.
53. As a Foreman user, I want incomplete output reported separately from authoritative host outcomes, so that a logging problem does not rewrite execution truth.
54. As a Foreman user, I want the AAP job ID and URL exposed to authorized users, so that advanced diagnosis can continue in AAP.
55. As a Foreman user, I want an AAP-backed invocation never to fall back to a Smart Proxy, so that audit and credential boundaries remain stable.
56. As a Foreman administrator, I want unsupported proxy-specific options rejected before publication, so that unusable artifacts are not created.
57. As a Foreman administrator, I want the AAP driver clearly marked experimental, so that operators understand its limited compatibility and feature set.
58. As a Foreman administrator, I want AAP support delivered as an optional plugin, so that removing it also removes AAP-specific configuration and behavior without affecting proxy execution.
59. As a maintainer, I want the AAP plugin to register through a sanctioned driver seam, so that it does not depend on load order or private implementation details in REX and `foreman_ansible`.

## Implementation Decisions

- The public remote execution provider remains `Ansible`. A new global driver setting selects proxy or AAP behavior. Its default is proxy.
- The selected driver is persisted on each Job Invocation at creation time. Setting changes affect only subsequently created invocations. Proxy-backed and AAP-backed invocations can overlap while each remains locked to its original driver.
- Each recurring occurrence is a separate Job Invocation and selects the current driver when that occurrence is created.
- `foreman_remote_execution` provides the smallest sanctioned seam needed for a provider to select an alternative top-level execution action. The existing action remains the default so other providers do not need to change.
- `foreman_ansible` owns the Ansible driver registry and the default proxy adapter. It selects a registered driver using the value persisted on the Job Invocation.
- A new optional `foreman_ansible_aap` plugin depends on `foreman_remote_execution` and `foreman_ansible`, registers the `aap` adapter, and owns the aggregate action tree, AAP and Git configuration, Git publication, AAP client, polling, event ingestion, result reconciliation, and cancellation implementation.
- The new plugin is scaffolded from the official `foreman_plugin_template` repository using its supplied rename workflow. Template example models, controllers, views, widgets, tasks, permissions, and JavaScript are removed unless the AAP implementation needs them.
- The AAP plugin must use the sanctioned driver seam rather than overriding private action classes, replacing constants, or depending on plugin load order.
- Installing the AAP plugin does not introduce a second public provider type. Existing Ansible Job Templates continue to use provider type `Ansible`.
- Removing or disabling the AAP plugin removes the AAP adapter and its configuration while leaving the proxy adapter and existing proxy execution behavior intact. Administrators must not disable it while AAP-backed invocations still require its implementation.
- The AAP plugin has its own release and packaging lifecycle and must declare compatible `foreman_ansible` and `foreman_remote_execution` versions.
- AAP mode uses a dedicated aggregate action tree rather than adding AAP branches throughout the existing proxy lifecycle.
- All lightweight per-host tasks are planned immediately. Foreman concurrency limits, proxy batch sizes, and chunked sub-plan creation do not apply.
- Each per-host task owns its local permission check, Template Invocation creation and association, and preparation validation. Preparation failures remain attached to that host task and do not prevent other hosts from proceeding.
- Invocation-scoped template inputs are resolved once. Host-varying inputs are unsupported; host-specific runtime data must come from inventory variables or facts.
- Successfully prepared per-host tasks wait for the aggregate result. They never render, publish, launch, poll, or cancel independently.
- The aggregate action is the sole owner of external I/O: AAP preflight, rendering, Git publication, AAP launch, polling, event ingestion, and cancellation.
- If every host fails preparation, no AAP preflight occurs, no playbook is rendered, no Git ref is created, and no AAP launch request is made.
- The playbook is rendered once without a current-host context. Host-dependent rendering constructs fail naturally. The POC does not add a proactive compatibility validator or an `AAP compatible` template flag.
- In practical Foreman usage a Job Invocation selects one Job Template. The POC does not design for combining multiple rendered Ansible playbooks into one AAP job.
- The rendered playbook must not embed secrets. The POC documents this as an unsupported template pattern rather than attempting complete secret detection.
- Proxy selection, proxy batch size, Foreman-managed SSH credentials, Foreman effective user, host-filtered cancellation, and other proxy-specific execution behavior are unsupported in AAP mode.
- AAP owns credentials, privilege escalation, execution environment, capacity, forks, verbosity, and execution timeout. Mapping additional Foreman concepts onto promptable AAP job properties is deferred.
- Foreman polls through AAP queued, waiting, and running states without imposing another execution deadline.
- The integration initially targets AAP 2.6 through a configured controller API base URL. Automatic version discovery and legacy Tower compatibility are out of scope.
- AAP authentication uses one encrypted OAuth bearer token for a dedicated service account. Per-user tokens are deferred.
- TLS certificate verification is mandatory. An administrator may configure a CA bundle; disabling verification is not supported.
- Git authentication is configured and encrypted separately from AAP authentication.
- Administrators pre-provision the dedicated Git repository, base ref, fixed generated playbook path, AAP Project, inventory source, Job Template, credentials, branch override, prompt-on-launch fields, and update-on-launch behavior.
- Foreman branches each invocation artifact from the current administrator-configured base ref. Shared files and dependency declarations from that base are available to the generated playbook.
- Foreman writes the rendered playbook at one fixed configured path. The AAP Job Template always selects that path; the SCM ref chooses the invocation-specific content.
- AAP remains responsible for installing Project roles and collections during normal Project synchronization.
- Relative playbook assets work when present in the base Project. Foreman does not validate them proactively.
- The generated ref name is deterministic and includes both a configured Foreman instance identifier and immutable Job Invocation identifier.
- Foreman publishes only to a dedicated machine-managed repository. It creates immutable refs but does not initialize, delete, prune, force-update, retain, or otherwise administer the repository.
- Git-side credential scope, branch protection, retention, and cleanup are recommendations for the repository administrator, not behavior Foreman enforces.
- Foreman records the repository identity, generated ref, and generated commit SHA. It does not separately persist the base commit or promise a second retained copy of the rendered playbook.
- If the deterministic remote ref exists with matching content, publication can be treated as successful. If it exists with different content, the invocation fails rather than overwriting it or selecting another name.
- The configured AAP Job Template has a fixed Project, fixed Foreman-synchronized inventory, fixed generated playbook path, AAP-owned credentials, and AAP-owned execution environment.
- Before publication, runtime preflight verifies AAP availability and authorization plus the Job Template's Project, repository URL, inventory, playbook path, branch override, limit prompt, and variables prompt.
- The POC has no configuration wizard or separate test-connection workflow. Configuration failures appear through normal Job Invocation execution.
- Foreman relies on the AAP inventory source's update-on-launch behavior. It does not launch inventory synchronization explicitly or prevalidate membership for every target.
- One Foreman Job Invocation maps to at most one AAP playbook job. AAP Project and inventory updates are accepted prerequisites and are not counted as additional playbook jobs.
- AAP launch data contains only the immutable SCM ref, an exact Ansible limit for successfully prepared host names, and correlation metadata including Foreman instance and Job Invocation identifiers.
- If the launch response reports that the SCM ref, limit, or correlation variables were ignored despite preflight, Foreman immediately requests cancellation and fails the invocation.
- The fixed inventory cannot be overridden at launch. Arbitrary user-authored AAP filters and general-purpose launch variables are not accepted.
- Foreman canonical host names are the identity contract and must exactly match AAP `inventory_hostname`. Existing Foreman hostname validation is sufficient; the POC adds no second hostname syntax validator.
- The Ansible limit constrains primary play hosts but is not treated as a security sandbox. Trusted rendered playbooks retain normal delegation and external-contact capabilities.
- If AAP reports that an event belongs to a prepared `inventory_hostname`, Foreman attaches it to that host's Template Invocation even when the task was delegated elsewhere.
- Events that cannot be mapped to a prepared Foreman host are retained as invocation-level diagnostics. They neither create Template Invocations nor fail the invocation solely because they exist.
- Final Foreman accounting iterates only over prepared hosts. Extra AAP host summaries do not enlarge the Job Invocation's result set.
- AAP job events are the source of live output. AAP job-host summaries are the authoritative source of final per-host outcomes.
- Event ingestion follows all pagination links, deduplicates by durable AAP event identity, persists its cursor/state, and performs a final catch-up after terminal job state.
- Host tasks receive success, error, or cancellation results from their preparation result and matching final AAP summary. This preserves current progress, failed-host selection, and rerun behavior.
- A prepared host absent from final host summaries is failed. A failed aggregate AAP status does not erase successful host summaries, and aggregate success does not override a failed host summary.
- Unscoped startup or playbook errors are recorded on the overall task and fail all otherwise unfinished prepared hosts without duplicating the same output into every host log.
- Event-ingestion failure is reported as incomplete output but does not replace authoritative host outcomes when final summaries remain available.
- Whole-job cancellation is coordinated only by the aggregate action. After AAP accepts cancellation, Foreman continues polling until terminal state, preserves completed outcomes, and marks unfinished hosts cancelled.
- Cancellation before AAP launch prevents launch and leaves any already-published immutable Git ref untouched.
- Network errors, rate limiting, and AAP 5xx responses are transient polling failures and use bounded exponential backoff. Authentication or authorization failures, a deleted remote job, and structurally invalid responses are permanent integration failures that fail unfinished hosts.
- Foreman persists the locked driver, Git coordinates, AAP job ID and URL, and event-ingestion state so restart behavior does not depend on current global settings.
- Foreman does not automatically retry an AAP launch if the request may have reached AAP without returning a persistable job ID. It performs no read-only reconciliation search. The invocation fails hard and warns that a remote job might still be running.
- A definitive failure during preflight, rendering, publication, or launch fails every successfully prepared host with the shared error while retaining earlier host-specific preparation errors.
- Failed-host rerun creates a new Job Invocation, resolves inputs again, renders and publishes a new artifact, and launches one new AAP job limited to the failed set.
- The existing Ansible provider routes every Ansible Job Invocation through AAP while the global driver is AAP. Incompatible templates fail clearly and never fall back to proxies.
- Non-Ansible remote execution providers retain their existing behavior.
- The AAP driver and documentation are explicitly marked experimental and not feature-equivalent to proxy execution.

## Testing Decisions

- Tests should assert externally visible Job Invocation behavior rather than private action ordering. The primary seam is the aggregate AAP action in `foreman_ansible_aap`, invoked through normal Ansible provider and driver selection, with fake AAP and Git adapters.
- `foreman_remote_execution` tests should verify that providers can select an alternative top-level execution action and that the existing action remains the default.
- `foreman_ansible` tests should verify proxy-adapter registration, AAP-adapter registration when the optional plugin is loaded, persisted driver selection, and clear failure when a persisted driver is unavailable.
- The AAP plugin test suite should own all AAP- and Git-specific behavior. Proxy-specific tests remain in `foreman_ansible` and generic execution-action seam tests remain in `foreman_remote_execution`.
- A deletion-style integration test should demonstrate that running without `foreman_ansible_aap` leaves existing Ansible proxy execution unchanged and exposes no selectable AAP driver.
- High-level action tests should verify driver locking, all-host planning, host-specific preparation failures, partial preparation, zero prepared hosts, one render, one publication, one launch, and final per-host task results.
- Existing tests around `RunHostsJob`, `RunHostJob`, Job Invocation result scopes, and Ansible provider selection are the closest prior art for action planning, per-host task bookkeeping, progress, and rerun behavior.
- Git publisher contract tests should verify deterministic namespaced refs, fixed artifact paths, matching-ref idempotency, conflicting-ref failure, ambiguous-push recovery, and the absence of force-update or deletion behavior.
- AAP client contract tests should cover runtime preflight, fixed-resource verification, ignored launch fields, launch response persistence, cancellation, terminal status mapping, pagination, event deduplication, host-summary reconciliation, transient retries, and permanent API failures.
- Job Invocation tests should verify that setting changes do not affect existing invocations, while each new recurring occurrence selects the current driver.
- Output tests should verify incremental per-host events, unassociated invocation-level events, pagination catch-up, restart-safe deduplication, and incomplete-output reporting.
- Result tests should cover aggregate failure with partial host success, aggregate success with host failure, unreachable hosts, missing summaries, unexpected extra summaries, cancellation with completed hosts, and failed-host rerun selection.
- Controller/API tests should verify whole-job cancellation, rejection of host-filtered cancellation, exposure of authorized AAP job links, progress, output retrieval, and rerun behavior.
- Security-oriented tests should verify mandatory TLS validation, fixed inventory and Project checks, narrow launch fields, absence of proxy fallback, and failure when branch, limit, or variables overrides are not honored.
- Normal automated tests use fake AAP and Git clients and do not require network services.
- A separately documented live integration scenario must run against AAP 2.6 and a writable dedicated Git repository. It must demonstrate Project and inventory update-on-launch, multi-host execution, live output, native host summaries, partial preparation, missing inventory hosts, mixed results, Foreman restart during polling, rerun, delegation diagnostics, and cancellation.
- Successful mocked tests are insufficient for declaring the POC viable. The live scenario is required because Project synchronization, branch override, event attribution, and host-summary behavior are essential architectural assumptions.

## Out of Scope

- Replacing the public `Ansible` provider with multiple user-selectable providers.
- Mixing proxy-backed and AAP-backed Ansible jobs by host, template, user, organization, or invocation choice within one current global configuration.
- A broad redesign of generic REX orchestration beyond the narrow top-level action-selection seam required by the AAP adapter.
- Placing AAP-specific settings, Git publication, AAP communication, polling, or result reconciliation inside `foreman_ansible` or `foreman_remote_execution`.
- Exposing AAP as a separate public remote execution provider type instead of an adapter behind `Ansible`.
- Removing lightweight per-host Dynflow tasks or redesigning the generic REX result data model.
- Full compatibility with task-based host searches and peripheral UI integrations not needed to demonstrate the POC.
- Foreman-side batching, concurrency mapping, or AAP job slicing.
- Host-filtered cancellation.
- Automatic proxy fallback.
- Multiple AAP configurations, organizations, inventories, Projects, or Job Templates selected per invocation.
- Per-user AAP authentication or propagation of Foreman user identity into AAP authorization.
- Mapping Foreman effective user, verbosity, timeout, concurrency, credentials, check mode, tags, or other execution concepts onto AAP prompts.
- Passing Foreman-managed SSH, vault, privilege-escalation, or other machine secrets to AAP.
- Proactive validation of template compatibility, relative assets, host-specific rendering constructs, or embedded secrets.
- A template-level `AAP compatible` flag.
- Foreman-managed inventory synchronization or target-membership preflight.
- Provisioning or administering the Git repository, AAP Project, inventory source, Job Template, credentials, service account, or branch protections.
- Repository cleanup, pruning, retention enforcement, or historical artifact verification.
- Retaining another copy of the rendered playbook in the Foreman database.
- Automatic AAP API version discovery, legacy Tower support, or versions other than the initial AAP 2.6 target.
- Automatic reconciliation or retry of ambiguous AAP launches.
- Treating the Ansible limit as a sandbox against delegation or other playbook-directed external access.
- Production support or feature-parity claims for the experimental driver.

## Further Notes

- AAP Job Template launch fields such as branch, limit, and extra variables can be ignored when their prompt-on-launch settings are disabled. Runtime preflight and launch-response validation are therefore safety requirements, not optional configuration polish.
- AAP Project and inventory update-on-launch should be documented as required setup. Foreman intentionally does not wait on separately launched synchronization requests because AAP owns those dependencies.
- The generated SCM commit is the durable artifact identity. Foreman records its coordinates, but artifact availability over time depends on repository administration outside Foreman.
- The service account should receive only the AAP permissions needed to inspect the configured resources, launch and cancel the fixed Job Template, and read its job, events, and host summaries.
- The POC intentionally accepts a small ambiguity window around AAP launch. When Foreman cannot persist an AAP job ID, it fails locally without retry or reconciliation even though the remote job might have started. This risk must be prominent in operator-facing diagnostics.
- The new plugin is intended to be a deep module: its small external interface is driver registration plus the selected top-level action, while AAP and Git complexity remains local to its implementation.
- The plugin split is not a license to relocate workarounds. Any behavior that requires patching private REX or `foreman_ansible` internals should first be evaluated as a missing sanctioned seam.
- If the POC proves the model, a subsequent production design should still revisit a first-class per-host execution-result abstraction in `foreman_remote_execution`; the lightweight per-host-task approach remains the initial compatibility strategy.
