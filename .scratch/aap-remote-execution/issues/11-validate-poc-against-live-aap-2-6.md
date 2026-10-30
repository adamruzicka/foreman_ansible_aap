# 11: Validate the POC against a live AAP 2.6 deployment

**What to build:** Demonstrate that the complete `foreman_ansible_aap` plugin works against real Git and AAP infrastructure and record whether its core architectural assumptions hold.

**Blocked by:** 10: Document the experimental AAP setup and limitations.

**Status:** ready-for-agent

- [ ] The documented environment uses a writable dedicated Git repository, AAP 2.6 Project with branch override, fixed Job Template, and Foreman-synchronized dynamic inventory.
- [ ] The live Foreman environment loads `foreman_ansible_aap` as an optional plugin alongside compatible REX and `foreman_ansible` versions.
- [ ] One multi-host Foreman Job Invocation produces one immutable Git ref and exactly one AAP playbook job.
- [ ] AAP performs its normal Project and inventory update-on-launch prerequisites and executes the invocation-specific playbook.
- [ ] The demonstration verifies one hostless render, exact primary-host limiting, AAP-owned credentials, and native structured events and host summaries.
- [ ] Live per-host output is visible in Foreman while the AAP job runs.
- [ ] Partial host preparation failure still launches the successfully prepared subset, while zero prepared hosts creates no external work.
- [ ] Mixed successful, failed, unreachable, missing-inventory, extra-summary, and delegated-task cases reconcile according to the spec.
- [ ] Polling resumes without duplicated or lost output after restarting the relevant Foreman process.
- [ ] Failed-host rerun creates a fresh artifact and AAP job for the expected host set.
- [ ] Whole-job cancellation preserves completed host outcomes and cancels unfinished hosts.
- [ ] Git conflict, ignored launch-field, transient polling, permanent observation, and ambiguous launch behaviors are exercised or simulated against the live boundary where practical.
- [ ] The validation report records payload scale, synchronization latency, event pagination behavior, operational limitations, and any divergence from the spec.
- [ ] The POC is not presented as production-ready unless every architectural assumption is validated and remaining risks are explicitly accepted in a follow-up design.
