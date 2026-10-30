# 03: Stream live AAP output durably

**What to build:** Have `foreman_ansible_aap` stream AAP job events into Foreman's existing output experience while the job runs, without losing or duplicating output across pagination, repeated polls, or Foreman restarts.

**Blocked by:** 01: Complete a successful multi-host AAP tracer bullet.

**Status:** ready-for-agent

- [ ] Polling consumes every page returned by the AAP job-events collection.
- [ ] AAP events mapped to a prepared `inventory_hostname` are written to that host's Template Invocation output.
- [ ] Events without a prepared-host mapping are retained as invocation-level diagnostics and do not create new Template Invocations.
- [ ] Delegated task output remains associated with the original inventory host when AAP reports that host relationship.
- [ ] Durable AAP event identities prevent duplicate output when polling returns previously observed events.
- [ ] Event-ingestion state is persisted with the Job Invocation and survives a Foreman process restart.
- [ ] Users can observe newly ingested per-host output before the AAP job reaches a terminal state.
- [ ] Foreman performs a final complete event catch-up after AAP becomes terminal.
- [ ] Per-host output remains available through existing Job Invocation output interfaces even though the host task performs no remote execution itself.
- [ ] Automated tests cover multiple pages, duplicate events, unmapped events, delegation attribution, restart recovery, and late terminal events.
