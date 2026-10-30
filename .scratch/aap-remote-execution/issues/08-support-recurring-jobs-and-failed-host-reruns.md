# 08: Support recurring jobs and failed-host reruns

**What to build:** Preserve Foreman's recurring and rerun workflows through the registered AAP adapter by treating every occurrence or retry as a new independently locked and auditable Job Invocation.

**Blocked by:** 02: Preserve host-specific preparation failures; 04: Reconcile authoritative per-host outcomes.

**Status:** ready-for-agent

- [ ] A recurring definition remains driver-neutral until each occurrence creates its own Job Invocation.
- [ ] Every recurring occurrence locks the global Ansible driver active when that occurrence is created.
- [ ] Changing the driver does not alter occurrences that have already been created or started.
- [ ] Failed-host selection includes hosts that failed preparation, failed or were unreachable in AAP, or were missing from final AAP summaries according to existing Foreman rerun semantics.
- [ ] A rerun creates a new Job Invocation and resolves its invocation-level inputs again.
- [ ] When the new invocation selects AAP, it renders once, creates a new immutable Git ref, and launches one new AAP job limited to the rerun host set.
- [ ] The original invocation's Git and AAP coordinates remain unchanged and independently auditable.
- [ ] Automated tests cover multiple recurring occurrences across a driver setting change and reruns containing preparation, execution, unreachable, and missing-host failures.
