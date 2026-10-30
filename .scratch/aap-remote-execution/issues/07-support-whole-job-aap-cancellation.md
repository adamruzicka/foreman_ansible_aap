# 07: Support whole-job AAP cancellation

**What to build:** Let `foreman_ansible_aap` cancel an AAP-backed Foreman Job Invocation as one execution unit while preserving work that AAP demonstrably completed.

**Blocked by:** 03: Stream live AAP output durably; 04: Reconcile authoritative per-host outcomes.

**Status:** ready-for-agent

- [ ] Whole-job cancellation sends exactly one cancellation request for the persisted AAP job ID.
- [ ] An accepted AAP cancellation request does not immediately terminate Foreman polling.
- [ ] Foreman continues ingesting events and polling until AAP reports a terminal state.
- [ ] Hosts with completed terminal summaries retain their actual successful or failed outcomes after cancellation.
- [ ] Prepared hosts without a completed outcome are marked cancelled after AAP reaches its cancelled state.
- [ ] Cancellation before AAP launch prevents launch and marks the remaining host tasks cancelled.
- [ ] Cancellation after Git publication leaves the immutable generated ref untouched.
- [ ] Lightweight host tasks never send independent or duplicate AAP cancellation requests.
- [ ] Automated tests cover cancellation before publication, after publication but before launch, while queued, while running, after some hosts finish, and after AAP is already terminal.
