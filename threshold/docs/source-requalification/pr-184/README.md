# Finite current source requalification proposal for PR 184

Status: **PROPOSAL ONLY. No admission, policy activation, or self-use.**

The user expressly requested conflict, finding, and governance repairs, complete
reviews, and conditional source merges. The original H1-B admission remains HOLD:
its original receipt, accepted pre-product evidence, and test-path scope have not
been recovered. No owner decision or human review is invented here.

The current autonomous lease forbids `src/test/**` and `src_test_changes`, permits
one file per candidate, and does not admit `industrial_refactoring_h1b`. The actual
structural source change plus regression tests cannot truthfully be called an
ordinary one-file classified autonomous candidate. This proposal requests a
separately reviewed finite manual source rule. It changes no current gate or lease.

## Concrete witness

`proposal.json` pins proposal base `49c5fcbdb7db5a2bba0b7f23133cff2d60e642d2`,
the two exact paths, their before/after Git blobs and SHA256 hashes, and the complete
canonical product patch. Missing before-blob for the added test is explicit null.

Published draft [PR 201](https://github.com/formatunitedandreas-code/spring-framework-petclinic/pull/201)
retains immutable tested source `45128d9e3877f8254bc68cb99d212b3eed8d4d8c` so CI can
fetch the actual objects. Its final product delta is exactly the two files. Its
older governance snapshot is not an admitted current policy. The documentary
proposal does not import that source ancestry.

`maven-test.log` preserves the unaltered full Maven output from the actual test at
that witness: **126 tests, zero failures/errors/skips, BUILD SUCCESS**. The manifest
binds the log bytes and the complete `src` tree, `pom.xml`, `.mvn`, and both Maven
wrappers. A digest proves byte identity, not that an old attempt had admission.
Fresh CI on any newly proposed source head remains required.

## Proposed mechanism, subject to root's independent policy review

1. A separate ordinary governance PR would implement a finite manual-source
   validator and accept a registration referring to this exact published witness,
   product patch, test-input trees, full log, and explicit current user repair
   scope. It must pass normal governance and independent review before any use.
   This documentary proposal is not that accepted registration.
2. The validator must read the registration from the actual target base, never
   trust a registration supplied only by the source branch, and require that
   target base to be an ancestor of the proposed source head. The current PR base
   and exact head must be bound by the observed PR event and independently checked
   review. Source PR metadata alone cannot create permission.
3. The accepted registration pins the proposal's source base and before blobs.
   After its normal policy merge, the fresh source PR must pin its actual current
   target SHA. That SHA must descend from the accepted registration and pinned
   proposal base; its full test inputs before the two-file delta must still match
   the pinned baseline. Any product/test-input drift requires a new reviewed
   registration, not silent rebasing of old qualification.
4. The source PR's entire final delta may change **only the two registered paths**,
   with the exact modes, before/after blob identities and full patch. It may not
   edit the registration, validator, workflow, lease, receipt inventory, KG,
   trainer, or learning state. All final test inputs after the delta must equal the
   published tested witness. No per-file substitution or partial witness qualifies.
5. Fresh Maven CI must test the newly proposed source version using the ordinary
   current test workflow. The conditional merge also requires the actual exact-head
   independent source review, no unresolved findings, and all required checks
   green. Local historical output never substitutes for those current checks.
6. All ordinary autonomous admission and provenance checks remain unchanged for
   every other change. This finite manual rule must not widen autonomous classes
   or the active lease. It must explicitly deny KG/trainer learning, runtime,
   provider calls, installation, cohort activation, or any effect beyond the
   user-directed current source review and conditional Git merge.

The implementation could qualify original PR 184's **current final head** after
ordinary refresh if the accepted finite rule verifies that exact final tree and
explicitly treats old execution history as nonasserted. Alternatively, a fresh
source PR could carry the same two-file delta. This choice is pending root review.
If a fresh PR is used, original 184 may become historical-only only after the exact
functional source/test delta is actually integrated. No archival step may silently
discard the functional goal.

## Required adversarial checks before accepting the mechanism

Reject missing/unaccepted or source-branch-only registration; changed base or
test-input tree; extra path; altered file mode, before/after blob, patch or log;
omitted test file; unavailable witness objects; fabricated counters or test-head
binding; edits to policy/lease/KG/trainer; missing/stale independent review; and red
fresh CI. Preserve unknown evidence as HOLD. Positive fixtures must use the actual
producer/validator and real Git objects, and must not authorize a runtime effect.

Root has not yet accepted this mechanism. `qualificationGranted=false`,
`authorityCreated=false`, `RuntimeAuthority=NONE`, `ExecutionAuthorized=false`.
