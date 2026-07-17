# Owner Search Use Case V0.1

runId: owner-search-p2-05-use-case-20260717T140500Z

## phaseId

P2-05 introduce_owner_search_port_and_use_case

## inputHead

6cec156

## expectedEffect

Introduce framework-free Owner Search application use case and outbound query port.

## changedPaths

- `src/main/java/org/springframework/samples/petclinic/owner/port/OwnerSearchQuery.java`
- `src/main/java/org/springframework/samples/petclinic/owner/application/SearchOwners.java`
- `src/test/java/org/springframework/samples/petclinic/owner/application/SearchOwnersTests.java`
- `threshold/docs/OWNER_SEARCH_USE_CASE_V0_1.md`
- `threshold/receipts/owner-search-p2-05-use-case-20260717T140500Z.json`

## behavior

- `null` last name is normalized to `""`.
- Non-null last name is passed through unchanged.
- The use case returns `OwnerListItem` values from the port in order.
- The returned list is defensively copied.

## validationCommands

- `git diff --check`
- `$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd -Dtest=SearchOwnersTests test`

## outcome

use_case_recorded

## validationResults

- `git diff --check`: passed
- `SearchOwnersTests`: 4 tests, 0 failures, 0 errors, 0 skipped

## nonClaims

- This phase does not implement adapter projections.
- This phase does not migrate the controller.
- This phase does not change query counts.
