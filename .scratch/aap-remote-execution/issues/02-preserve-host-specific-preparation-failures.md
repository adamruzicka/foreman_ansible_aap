# 02: Preserve host-specific preparation failures

**What to build:** Extend the `foreman_ansible_aap` adapter to preserve Foreman's host-specific permission and preparation behavior while allowing the successfully prepared subset to continue through one aggregate AAP job.

**Blocked by:** 01: Complete a successful multi-host AAP tracer bullet.

**Status:** done

- [x] Each lightweight host task performs its own permission check, Template Invocation creation and association, and local preparation validation.
- [x] Preparation errors are visible on the affected host task and do not become an undifferentiated aggregate error.
- [x] Successfully prepared hosts continue to one aggregate render, publication, and AAP launch when other hosts fail preparation.
- [x] The AAP launch limit contains only successfully prepared hosts.
- [x] Invocation-level inputs are resolved once and made consistently available to every prepared host record.
- [x] Host-varying template inputs and host-context rendering fail clearly rather than choosing an arbitrary host.
- [x] If every host fails preparation, Foreman performs no AAP preflight, rendering, Git publication, or AAP launch.
- [x] A shared failure after preparation fails all prepared hosts while preserving earlier host-specific preparation errors.
- [x] Automated tests cover complete preparation success, partial preparation failure, permission failure, host-dependent rendering failure, and zero prepared hosts.
