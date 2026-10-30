# 06: Handle polling and output failures safely

**What to build:** Make `foreman_ansible_aap` keep remote observation reliable through temporary AAP failures and report permanent observation or output failures without inventing successful execution results.

**Blocked by:** 03: Stream live AAP output durably; 04: Reconcile authoritative per-host outcomes.

**Status:** ready-for-agent

- [ ] Network failures, rate limiting, and AAP 5xx responses retry using bounded exponential backoff while the Job Invocation remains active.
- [ ] Temporary polling failures do not change per-host task outcomes.
- [ ] Authentication failures, authorization failures, a deleted AAP job, and structurally invalid API responses are treated as permanent integration failures.
- [ ] Permanent integration failures fail every unfinished prepared host with an actionable diagnostic.
- [ ] Foreman does not impose a retry deadline that replaces AAP's own queued, capacity-waiting, running, or timeout behavior.
- [ ] Failure to ingest some output is reported as incomplete output when final host summaries remain available.
- [ ] Incomplete output does not replace authoritative host outcomes or turn successful hosts into failures.
- [ ] Persisted polling and event state prevents replay corruption after recovery from a transient error or process restart.
- [ ] Automated tests cover each transient and permanent error class, backoff behavior, recovery, incomplete output with valid summaries, and permanent loss of observability.
