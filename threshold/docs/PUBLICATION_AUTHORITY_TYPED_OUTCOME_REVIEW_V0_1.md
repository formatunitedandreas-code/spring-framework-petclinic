# Publication Authority Typed Outcome Review v0.1

## Bound Heads

PetClinic repository:

- Branch: `codex/petclinic-semantic-adapter-hardening`
- Head: `5ed49af7e96b9c2cd31c6c50e6c7e0ddcd23154d`
- Tree: `5357916ca5e6969532702786214b5bf6df77eed0`
- Remote push target: `origin/codex/petclinic-semantic-adapter-hardening`
- Remote URL: `https://github.com/formatunitedandreas-code/spring-framework-petclinic.git`

Threshold Core repository:

- Branch: `codex/threshold-semantic-maturity-hardening`
- Current local head observed during this review: `2f7629148679855e15016619efc990bc744784ac`
- Current local tree observed during this review: `a043a2ad06fc3b9a493ee0cb1238704372ae6029`
- Previously expected head for the adapter work: `f1781748f4e495a834486c9d7096e5936f6ff92a`
- Previously expected tree: `d93765c2a3c9ddb686bb865a1baa23862788a5cc`
- Baseline note: the current Core branch advanced after the PetClinic adapter commit. This document records the deviation; it does not silently rebind the earlier expected Core head.

## Push Provenance

The PetClinic governance-lane commit `5ed49af7e96b9c2cd31c6c50e6c7e0ddcd23154d` was pushed to `origin/codex/petclinic-semantic-adapter-hardening`.

This record is provenance only. It does not create, imply, or backfill any missing publication, merge, release, deploy, or external authority.

## Independent Read-Only Review

Review scope:

- PetClinic head `5ed49af7e96b9c2cd31c6c50e6c7e0ddcd23154d`
- Threshold Core current head `2f7629148679855e15016619efc990bc744784ac`
- Threshold Core previously expected head `f1781748f4e495a834486c9d7096e5936f6ff92a`

Review conclusion:

- PetClinic publication preflight no longer consumes `decision`, `reasonCodes`, `decisionFor(...)`, or reason-string containment as the authority decision surface.
- PetClinic consumes typed Core outcomes for the publication decision: `valid`, `evaluatedHead`, `inputDigest`, `effectDecisions.publication.allowed`, `effectDecisions.publication.failedConstraintIds`, and `failedConstraintIds`.
- Reason codes remain visible as diagnostic/readout data.
- Legacy stop strings are projected from typed failed constraints after the typed publication effect decision has been evaluated.
- Head, branch, and tree are checked before and after Core validation; the prepared publication action readout is bound to the rechecked head.

Specific authority-boundary finding:

- `failedConstraintIds` are diagnostic and projection data once the complete typed publication effect decision has been evaluated.
- `failedConstraintIds` alone do not authorize publication.
- The authoritative decision remains the complete typed publication effect decision plus the subsequently revalidated head, branch, and tree.

Review status: closed.

## TOCTOU Fixture

The main-repo detached-HEAD mutation fixture can be skipped in sandbox profiles where `.git` is read-only. To close that gap, `threshold/scripts/test-publication-toctou-isolated-fixture.ps1` runs the same branch-change class in an isolated writable Git repository under `threshold/runtime/`.

Expected result:

- `expectedStop=isolated-post-cli-head-detached`
- `publicationToctouIsolatedFixture=passed`

## Somnium Inventory

Core package:

- Name: `@threshold/somnium-loop`
- Package path: `packages/somnium-loop`
- Main export: `dist/index.js`
- Type export: `dist/index.d.ts`
- Key source files:
  - `src/index.ts`
  - `src/types.ts`
  - `src/somniumLoop.ts`
  - `src/eligibility.ts`
  - `src/math.ts`
  - `src/retrieval.ts`
  - `src/somniumLoop.test.ts`

Observed exported surfaces:

- `runSomniumLoop`
- `toSomniumSignals`
- `isSomniumEligible`
- `defaultSomniumOptions`
- Somnium math/retrieval helpers
- `SomniumChunkyBias`
- `SomniumResult`
- `SomniumSignals`

Relevant contract:

- Somnium is a soft local depth layer.
- Somnium does not bypass AQAL, Chunky, Daimon, or publication authority.
- Somnium emits reason codes and bias signals, including `SOMNIUM_SOFT_BIAS_ONLY` and `SOMNIUM_NO_HARD_CONTROL`.
- Somnium can inform audit/readout, but it is not a hard controller.

## Reuse Decision

Decision: reuse the existing Somnium contract as readout context only and implement a thin PetClinic reason-boundary adapter.

Rationale:

- The existing Somnium package already models non-authorizing reason and bias signals.
- PetClinic should not import Somnium as a publication gate at this point.
- The immediate need is an audit adapter proving that reason-like data cannot authorize publication.

Implemented adapter:

- `threshold/scripts/audit-publication-reason-boundary.ps1`

Adapter status:

- Non-authorizing.
- Runtime report only.
- It validates that PetClinic publication authority remains bound to typed effect decisions and rechecked head, branch, and tree.
## Current Recommendation

The current implementation state supports this action order:

1. Keep the existing `@threshold/somnium-loop`; do not create a second Somnium or reason-decision implementation.
2. Treat Somnium output as hypothesis and shadow evidence only.
3. Keep typed Core constraints as the only publication and merge decision surface.
4. Keep PetClinic consumption limited to typed Core publication outcomes plus post-validation head checks.
5. Require a fresh independent review before any later publication or merge authority.

Required Somnium boundary invariants now carried by the PetClinic adapter review surface:

- `SomniumDecision <= GuardianDecision <= AuthorityDecision`.
- Reason renaming and reason ablation must not change effect decisions when predicate and constraint outcomes are unchanged.
- Somnium outputs must not feed back as training truth through telemetry, Chunky bias, KG projection, or generated training artifacts without separate grounding and independent review.
- `shadow_ready` is only technical observation readiness; it is not `production_ready`, `authority_validated`, `finding_closed`, `publicationReady`, or `mergeReady`.

Allowed terminal status for this lane remains:

```json
{
  "somniumReasonAuditStatus": "shadow_ready",
  "authorizing": false,
  "allowedEffects": ["observe", "shadowIntegration"],
  "publicationReady": false,
  "mergeReady": false,
  "independentReview": false
}
```
