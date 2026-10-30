# 05: Harden Git publication and AAP launch safety

**What to build:** Harden the Git and AAP adapters inside `foreman_ansible_aap` so publication and launch are deterministic, narrowly authorized, and safely failing when repository state or AAP configuration differs from the expected fixed contract.

**Blocked by:** 01: Complete a successful multi-host AAP tracer bullet.

**Status:** ready-for-agent

- [ ] Generated refs include the configured Foreman instance identifier and immutable Job Invocation identifier.
- [ ] Foreman creates refs but never force-updates, deletes, prunes, or otherwise administers the dedicated repository.
- [ ] An existing deterministic ref with identical generated content is accepted as an idempotent publication result.
- [ ] An existing deterministic ref with different content fails the invocation without overwriting it or selecting another name.
- [ ] Runtime preflight occurs after local host preparation and before rendering or Git publication.
- [ ] Preflight verifies the fixed Job Template, inventory, Project, repository URL, generated playbook path, branch override, host-limit prompt, and variables prompt.
- [ ] Foreman supplies only the SCM ref, exact prepared-host limit, and correlation metadata at launch; inventory and arbitrary variables cannot be overridden.
- [ ] A launch response that reports the ref, limit, or correlation variables as ignored triggers an immediate cancellation request and fails the invocation.
- [ ] A definitive rendering, publication, or launch failure fails every prepared host with the shared diagnostic.
- [ ] A launch whose response cannot be safely obtained or persisted fails hard, is not retried or reconciled, and prominently warns that AAP might still be executing.
- [ ] AAP failure never triggers Smart Proxy fallback.
- [ ] Automated tests cover matching and conflicting refs, invalid fixed-resource configuration, ignored launch fields, definitive launch failure, ambiguous launch failure, and absence of fallback.
