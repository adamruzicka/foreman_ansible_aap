# Experimental AAP execution driver

`foreman_ansible_aap` is an optional Foreman plugin that was scaffolded from
the official `foreman_plugin_template`. Its AAP driver is experimental and is not production-ready.
It is not feature-equivalent to Smart Proxy execution,
and it has not been validated against a live AAP 2.6 deployment. The separate
[AAP 2.6 live-integration scenario](aap-2.6-live-integration.md) describes the
validation still required.

Installing this plugin only registers another driver behind the existing
Ansible provider. The Smart Proxy driver remains the default. Enabling AAP is
an explicit global choice, and a Job Invocation keeps the driver selected when
it was created. A recurring occurrence is a new invocation and reads the
current global setting.

## Compatible Foreman plugins

Install the plugin alongside these declared runtime ranges:

- `foreman_ansible >= 18.0, < 19`
- `foreman_remote_execution >= 17.2, < 18`

Use normal Foreman plugin packaging for the installation, migrate the Foreman
database, and restart Foreman and its Dynflow workers. Do not disable or remove
the plugin while an AAP-backed invocation is still running or needs to resume.
The plugin owns its database tables and all AAP-specific settings; removing it
does not change proxy-backed Ansible execution.

For an unpackaged evaluation checkout, add the plugin gem to the same Bundler
application as Foreman and the two compatible plugins, install the bundle, then
run the normal Foreman migration command:

```sh
foreman-rake db:migrate
```

Use the platform's normal service manager to restart both the web and Dynflow
worker processes. Confirm the plugin appears in Foreman's loaded-plugin list
before configuring any AAP values. Package names, service names, and the
Bundler entry depend on the evaluation platform, so this POC does not prescribe
production packaging commands.

Leave `ansible_execution_driver` set to `proxy` while preparing and checking
the resources below. Set it to `aap` only in a non-production evaluation
environment after the complete contract is in place. The setting applies to
new invocations; it does not move an existing invocation between backends.

## Provision the dedicated Git repository

Create a repository used only for generated Foreman execution artifacts. The
repository must already exist and have a base ref such as `main`. Put any
shared roles, collections, dependency declarations, and relative files needed
by the rendered playbook on that base ref.

Choose one fixed relative playbook path. The default is
`generated/foreman.yml`. The same value must be configured on the AAP Job
Template and in `aap_generated_playbook_path`. Absolute paths, `..` path
components, and symbolic links in the destination path are rejected.

Give Foreman a repository credential that can clone the base ref, inspect
remote refs, and create branches. Give AAP a different read credential for its
Project. Do not reuse the AAP service token or an AAP machine credential for
Git. Foreman supplies Git credentials through a non-interactive askpass helper;
it does not place them on the Git command line.

Each invocation is branched from the configured base ref and published under
the deterministic namespace
`foreman/<instance-id>/job-invocation-<id>`. Use a stable, unique instance ID
made from conservative Git-ref characters, for example `lab-foreman-01`.
Foreman records the repository URL, generated ref, and commit SHA.

Publication is append-only: Foreman creates immutable refs and never forces,
deletes, prunes, or rewrites them. A retry accepts an existing ref only when
the generated file has identical content; different content is a hard
conflict. Repository provisioning, access policy, branch protection,
credential rotation, retention, cleanup, backup, and historical artifact
availability are administrator responsibilities. Foreman does not retain a
second copy of the rendered playbook and cannot guarantee that an old artifact
will remain available after repository cleanup.

## Provision the AAP 2.6 resources

Use AAP 2.6 and create these fixed resources before enabling the driver:

1. Create one Project backed by the dedicated repository. Its SCM URL must
   exactly match `aap_repository_url`; equivalent SSH and HTTPS spellings are
   not canonicalized. Enable Project update-on-launch and attach AAP's
   repository read credential.
2. Create one dynamic inventory synchronized from Foreman. At least one of its
   inventory sources must have update-on-launch enabled. Foreman does not
   start inventory updates itself and does not preflight every target's
   membership.
3. Create one Job Template selecting that Project, that inventory, and the
   exact fixed generated playbook path. Enable **Prompt on launch** for SCM
   branch, limit, and variables (`ask_scm_branch_on_launch`,
   `ask_limit_on_launch`, and `ask_variables_on_launch`). This branch override
   is how AAP selects the invocation-specific ref. Do not make inventory or
   Project selectable at launch.
4. Select an execution environment on the Job Template and attach the AAP
   machine, vault, and privilege-escalation credentials it requires. These
   credentials are AAP-owned; Foreman credentials are not copied into AAP.
5. Configure capacity, forks, timeout, verbosity, and other execution policy
   in AAP. Foreman intentionally does not impose its own execution deadline
   while AAP reports the job as active.

Runtime preflight reads the fixed Job Template, Project, inventory, and
inventory sources. It verifies the Project and inventory IDs, playbook path,
Project SCM URL, Project `update_on_launch`, at least one inventory-source
`update_on_launch` flag, and all three required prompt fields. A mismatch fails
before Git publication. Project and inventory synchronization jobs created by
update-on-launch are AAP prerequisites; one Foreman invocation still launches
at most one AAP playbook job.

At launch Foreman sends only:

- the immutable generated ref as `scm_branch`;
- the comma-separated, exact prepared host names as `limit`; and
- the correlation variables `foreman_instance_id` and
  `foreman_job_invocation_id`.

If AAP reports that branch, limit, or variables were ignored or changed,
Foreman requests cancellation and fails the invocation.

### Least-privilege AAP service account

Create a dedicated service account and OAuth token. Grant only the functional
permissions required to:

- inspect the configured Job Template, Project, inventory, and inventory
  sources;
- launch the fixed Job Template and cancel jobs launched from it; and
- read those jobs, job events, and job-host summaries.

Do not grant general AAP administration or permission to launch arbitrary Job
Templates. AAP role names and inheritance can vary with resource ownership, so
verify the effective permission set with the dedicated account on AAP 2.6.
The single encrypted token is shared by AAP-backed invocations; per-user AAP
tokens and propagation of Foreman user identity are not supported.

## Configure Foreman

Configure the following settings under the Ansible settings category. Blank
defaults are intentional so installing the optional plugin does not require
AAP while proxy execution is selected.

| Setting | Required value |
| --- | --- |
| `aap_controller_url` | HTTPS AAP 2.6 controller API base ending in `/api/controller/v2/` |
| `aap_service_token` | Dedicated OAuth bearer token; stored encrypted |
| `aap_ca_bundle` | Optional CA bundle extending normal peer verification; TLS verification cannot be disabled |
| `aap_job_template_id` | Numeric ID of the fixed Job Template |
| `aap_inventory_id` | Numeric ID of the fixed Foreman-synchronized inventory |
| `aap_project_id` | Numeric ID of the fixed Project |
| `aap_repository_url` | Dedicated repository URL, exactly as AAP reports it |
| `aap_repository_base_ref` | Existing base ref; defaults to `main` |
| `aap_generated_playbook_path` | Fixed relative path; defaults to `generated/foreman.yml` |
| `aap_instance_id` | Stable Foreman namespace used in immutable refs |
| `aap_git_username` | Foreman's repository write username; stored encrypted |
| `aap_git_password` | Foreman's repository write password or token; stored encrypted |

The AAP and Git credentials are deliberately separate. `aap_ca_bundle` may add
a private CA, but the controller must use HTTPS and peer verification always
remains enabled.

After preflight resources and permissions have been checked, change
`ansible_execution_driver` from `proxy` to `aap`. Switch it back to `proxy` to
route only subsequently created invocations through Smart Proxies. There is no
automatic fallback: an incompatible or unavailable AAP execution fails and is
never retried on a proxy.

## Template and inventory contract

The rendered Job Template must not contain secrets. Rendering commits the
complete result to Git and AAP retains job artifacts. Hidden Foreman inputs can
still render secret material, and the plugin does not attempt comprehensive
secret detection. Keep secrets in AAP credentials or inventory variables.

The plugin renders once without a current Foreman host. Invocation-level
inputs work, but host macros, host facts, and other host-varying rendering are
incompatible. Host-specific runtime data must come from AAP inventory
variables or Ansible facts. Foreman does not proactively detect every
incompatible template or missing relative asset; rendering or AAP execution
fails naturally instead.

Foreman's canonical `host.name` must exactly equal the AAP
`inventory_hostname`, including case. Output and final host summaries are
matched with that exact identity. Inventory synchronization must finish with
all intended prepared hosts present before the playbook starts. If AAP returns
no final summary for a prepared host, Foreman fails that host and reports that
it either did not execute or was absent from synchronized inventory. Extra
summaries do not add hosts to the Foreman invocation.

The exact Ansible limit constrains the play's primary host set. Ansible limit
is not a security sandbox: a trusted playbook can still use `delegate_to`,
contact external services, or otherwise act outside that set. A delegated
event is attributed to the original inventory host when AAP reports
`event_data.host`; unassociated events are retained as invocation diagnostics.

## Unsupported behavior and concept mapping

AAP is a global Ansible execution driver, not another Smart Proxy. The
following are unsupported:

- proxy selection, proxy batching, and Foreman concurrency controls;
- Foreman-managed SSH passwords, keys, effective-user overrides, provider
  inputs, and execution-timeout overrides;
- host-filtered cancellation (only whole-job cancellation is supported);
- per-user AAP tokens or Foreman-user identity propagation;
- multiple AAP controllers, Projects, inventories, or Job Templates selected
  per invocation;
- legacy Tower versions, automatic API discovery, or versions other than the
  initial AAP 2.6 target;
- automatic fallback to a Smart Proxy; and
- general mapping of Foreman verbosity, timeout, concurrency, credentials,
  check mode, tags, or other proxy concepts onto AAP prompts.

The implementation rejects the proxy-specific controls it can identify before
publication, but it does not proactively detect every incompatible template.
Use this mapping when interpreting an AAP-backed invocation:

| Foreman concept | AAP behavior |
| --- | --- |
| Ansible Job Template | Rendered once into the fixed Project playbook path |
| Targeted, successfully prepared hosts | Exact AAP `limit` |
| Smart Proxy and its SSH credentials | Not used |
| Effective user and privilege escalation | AAP machine/become credentials |
| Foreman concurrency, timeout, and execution environment | AAP capacity, forks, Job Template timeout, and execution environment |
| Foreman user | Authorizes local preparation only; not an AAP identity |

## Failure, output, rerun, and cancellation semantics

Foreman streams paginated AAP job events into each host's normal Template
Invocation output and performs a final catch-up after the AAP job becomes
terminal. Output ingestion errors are reported as incomplete output; final
job-host summaries remain authoritative for host results. Failed and
unreachable summaries fail that host, successful summaries preserve success,
and a missing summary fails the prepared host. Failed-host rerun creates a new
Foreman invocation, immutable ref, and AAP job limited to that new target set.

Whole-job cancellation sends at most one cancellation request for the one AAP
job and continues polling until AAP becomes terminal. Completed host summaries
are preserved; unfinished hosts become cancelled. Cancellation before launch
prevents launch but does not remove an immutable ref that was already created.
Host-filtered cancellation is rejected because it cannot be represented by the
single aggregate AAP job.

Transient network, rate-limit, and AAP 5xx observation failures use bounded
backoff. Authentication, authorization, missing-job, and invalid-response
errors permanently fail unfinished hosts. Foreman does not impose a timeout on
an otherwise active AAP job.

### Ambiguous launch warning

There is an unavoidable hard-failure ambiguity window after Foreman sends the
launch request and before it durably stores the returned AAP job ID. If the
response or local persistence fails in that window, AAP might still be
executing even though Foreman marks the invocation failed. Foreman deliberately
does not retry the launch or search AAP for a correlation match, because a
retry could create a duplicate job. Operators must inspect AAP using the
Foreman instance and Job Invocation correlation values before taking further
action.

## Validation status

Automated tests use fake AAP transports and local Git repositories. They do
not validate AAP synchronization ordering, prompt behavior, event attribution,
pagination, or host-summary semantics against a real controller. Run the
[standalone live-integration scenario](aap-2.6-live-integration.md), record its
evidence, and treat every divergence as a design input. Passing mocked tests
alone is not evidence of production readiness.
