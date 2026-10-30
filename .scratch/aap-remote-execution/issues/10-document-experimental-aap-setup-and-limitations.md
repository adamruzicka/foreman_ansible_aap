# 10: Document the experimental AAP setup and limitations

**What to build:** Give administrators enough guidance to install `foreman_ansible_aap`, configure it, and safely evaluate its experimental AAP driver without implying production support or proxy feature parity.

**Blocked by:** 02: Preserve host-specific preparation failures; 05: Harden Git publication and AAP launch safety; 06: Handle polling and output failures safely; 07: Support whole-job AAP cancellation; 08: Support recurring jobs and failed-host reruns; 09: Expose AAP diagnostics and enforce unsupported controls.

**Status:** ready-for-agent

- [ ] Documentation identifies the driver as experimental and proxy as the default.
- [ ] Documentation explains that `foreman_ansible_aap` is an optional plugin scaffolded from the official Foreman plugin template and declares its compatible REX and `foreman_ansible` versions.
- [ ] Documentation covers the dedicated Git repository, base ref, fixed generated path, Foreman instance namespace, separate Foreman write and AAP read credentials, and Foreman's append-only behavior.
- [ ] Documentation covers the AAP 2.6 Project, fixed Job Template, fixed dynamic inventory, update-on-launch behavior, branch override, required prompt fields, execution environment, and AAP-owned machine credentials.
- [ ] Documentation lists the least AAP permissions needed to inspect configured resources, launch and cancel the fixed template, and read jobs, events, and host summaries.
- [ ] Documentation states that repository provisioning, permissions, retention, cleanup, and historical artifact availability are administrator responsibilities.
- [ ] Documentation states that rendered playbooks must not embed secrets and that Foreman does not proactively detect every incompatible template.
- [ ] Documentation explains exact host-name identity, inventory synchronization assumptions, missing-host failure, and the fact that Ansible limits do not sandbox delegation.
- [ ] Documentation lists unsupported proxy options, host-filtered cancellation, per-user AAP tokens, multiple AAP configurations, legacy Tower versions, automatic fallback, and concept mapping.
- [ ] Documentation explains the hard-failure ambiguity window in which AAP might be executing despite a failed Foreman launch.
- [ ] Documentation provides the separately runnable live-integration scenario and expected observations.
