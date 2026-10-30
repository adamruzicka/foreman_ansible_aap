# 09: Expose AAP diagnostics and enforce unsupported controls

**What to build:** Let `foreman_ansible_aap` present useful execution diagnostics through Foreman's existing Job Invocation interfaces while rejecting controls whose semantics cannot be preserved by a single aggregate AAP job.

**Blocked by:** 03: Stream live AAP output durably; 04: Reconcile authoritative per-host outcomes; 07: Support whole-job AAP cancellation.

**Status:** done

- [x] Authorized users can see the persisted AAP job ID and a direct AAP job URL from the Foreman Job Invocation.
- [x] Existing Job Invocation progress, per-host output, successful-host, failed-host, and rerun interfaces work with lightweight AAP bookkeeping tasks.
- [x] Host-filtered cancellation is rejected with a clear explanation and never broadens into whole-job cancellation.
- [x] Proxy selection, proxy batching, Foreman-managed SSH credentials, Foreman effective user, and other explicitly unsupported proxy options are rejected before Git publication.
- [x] AAP-backed invocations never silently fall back to Smart Proxy execution after configuration, publication, launch, polling, or cancellation failure.
- [x] Non-Ansible providers and proxy-backed Ansible invocations retain their existing controls and behavior.
- [x] Peripheral task-based searches and UI integrations not needed for the POC may remain unsupported, but their limitations are explicit rather than silently incorrect.
- [x] API and controller tests cover authorization of AAP links, output and progress retrieval, whole-job cancellation, host-filtered cancellation rejection, unsupported proxy options, and absence of fallback.
