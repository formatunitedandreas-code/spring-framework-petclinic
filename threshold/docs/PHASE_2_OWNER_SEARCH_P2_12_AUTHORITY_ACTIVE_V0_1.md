# Phase 2 Owner Search P2-12 Authority Active V0.1

phaseId: P2-12
lane: product_refactor
feature: owner_search_vertical_refactoring
candidateClass: owner_search_explicit_fetch_plans
authoritySource: user_one_shot_grant_2026-07-17-p2-12

## Grounding

- repository: `C:\dev\spring-framework-petclinic`
- branch: `agent/owner-search-explicit-fetch-plans`
- sourceHead: `16ca87d0a69b079c20351a048d7b082ca9b057f2`
- originMain: `16ca87d0a69b079c20351a048d7b082ca9b057f2`
- priorAcceptedPhase: P2-11
- priorMergedPr: #115

## Allowed Scope

- `src/main/java/org/springframework/samples/petclinic/**`
- `src/test/java/org/springframework/samples/petclinic/**`
- `src/main/resources/spring/**`
- `threshold/docs/**`
- `threshold/receipts/**`
- active lease and runtime-state files for this run

## Expected Effect

- Change `Pet.visits` from global eager materialization to default lazy materialization.
- Add explicit owner-detail and pet-context fetch plans for JPA and Spring Data JPA.
- Preserve owner search UI behavior.
- Preserve JDBC behavior.
- Avoid visit materialization on JPA and Spring Data JPA owner search list paths.

## Decision

decision: continue_to_local_validation

No publication, PR readiness, merge, release or deployment authority is inferred from this grant.
