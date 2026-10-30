# 01: Complete a successful multi-host AAP tracer bullet

**What to build:** In `foreman_ansible_aap`, make a successfully prepared multi-host Ansible Job Invocation render once, publish one immutable playbook artifact, launch one AAP playbook job, and settle every host successfully from AAP results.

**Blocked by:** None (can start immediately).

**Status:** done

- [x] Administrators can configure the AAP 2.6 controller endpoint, encrypted service token, CA bundle, fixed Job Template, fixed inventory, Project, repository identity, base ref, generated playbook path, instance identifier, and encrypted Git credentials.
- [x] TLS certificate verification is mandatory for AAP communication.
- [x] The aggregate action performs a successful runtime preflight of the fixed Job Template, inventory, Project, repository, playbook path, and required prompt-on-launch fields.
- [x] One invocation-level input set is rendered exactly once without an implicit current host.
- [x] The rendered playbook is committed at the fixed generated path on an invocation-specific immutable ref derived from the configured base ref.
- [x] Foreman persists the repository identity, generated ref, and generated commit SHA.
- [x] Foreman launches exactly one AAP playbook job with the immutable SCM ref, exact prepared-host limit, and Foreman correlation metadata.
- [x] The AAP job ID and URL are persisted before polling begins.
- [x] Foreman polls queued, waiting, and running states without imposing a separate execution timeout.
- [x] Successful AAP host summaries settle every prepared lightweight host task successfully.
- [x] The aggregate action is the only component that performs Git or AAP I/O.
- [x] All AAP settings, adapters, actions, persistence, and Git/AAP clients introduced by this ticket live in `foreman_ansible_aap`.
- [x] AAP Project and inventory synchronization jobs are accepted as launch prerequisites and do not count as extra playbook jobs.
- [x] The `foreman_ansible_aap` test suite exercises the full successful path through fake Git and AAP adapters and asserts one render, one publication, and one AAP launch.
