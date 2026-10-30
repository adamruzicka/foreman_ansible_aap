# 04: Reconcile authoritative per-host outcomes

**What to build:** Have `foreman_ansible_aap` translate AAP's aggregate job and final host summaries into accurate Foreman per-host task outcomes, including mixed, missing, delegated, and startup-failure cases.

**Blocked by:** 01: Complete a successful multi-host AAP tracer bullet.

**Status:** done

- [x] Final AAP job-host summaries are the authoritative source of prepared-host outcomes.
- [x] A failed or unreachable host summary fails the matching lightweight host task even when the aggregate AAP job reports success.
- [x] A successful host summary remains successful when the aggregate AAP job reports failure.
- [x] A prepared host absent from all final summaries fails with a diagnostic explaining that it did not execute or was not present in the synchronized inventory.
- [x] Extra AAP host summaries do not create Template Invocations, alter Foreman's target set, or fail the invocation solely because they exist.
- [x] Results reported for the original inventory host remain associated with that Foreman host when tasks use Ansible delegation.
- [x] Unscoped parser, startup, or playbook errors are recorded on the aggregate task and fail every otherwise unfinished prepared host.
- [x] Per-host task results continue to drive existing progress, successful-host, failed-host, and rerun selection behavior.
- [x] Automated tests cover aggregate failure with partial success, aggregate success with host failure, unreachable hosts, missing summaries, extra summaries, delegated tasks, and startup failure before host execution.
