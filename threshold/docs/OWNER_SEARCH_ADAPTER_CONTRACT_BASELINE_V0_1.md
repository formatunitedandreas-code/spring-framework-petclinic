# Owner Search Adapter Contract Baseline V0.1

runId: owner-search-p2-02-adapter-contract-20260717T130038Z

## phaseId

P2-02 adapter_contract_baseline

## inputHead

62122be0f073066a6290f81a9356dce367c00ba3

## inputDigest

- branch: `agent/owner-search-behavior-baseline`
- productSourceHead: `04f7e344e51ed6c75e9e3062ebc8ee7fa9415b1c`
- origin/main: `04f7e344e51ed6c75e9e3062ebc8ee7fa9415b1c`
- active grant: `p2-02-owner-search-adapter-contract-baseline`
- active lane: `product_refactor`

## allowedPaths

- `src/test/java/org/springframework/samples/petclinic/**`
- `threshold/docs/**`
- `threshold/receipts/**`
- active Authority runtime files under `threshold/lease-state/**` and `threshold/leases/**`

## expectedEffect

Add a common Owner Search adapter parity contract for the existing JDBC, JPA, and Spring Data JPA profile implementations without changing production logic.

## changedPaths

- `src/test/java/org/springframework/samples/petclinic/service/AbstractOwnerSearchContractTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/JdbcOwnerSearchContractTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/JpaOwnerSearchContractTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/SpringDataJpaOwnerSearchContractTests.java`
- `threshold/docs/OWNER_SEARCH_ADAPTER_CONTRACT_BASELINE_V0_1.md`
- `threshold/receipts/owner-search-p2-02-adapter-contract-20260717T130038Z.json`

## contractCoverage

- search by exact prefix
- search with empty string
- no results
- multiple owners
- owners without pets
- owners with multiple pets
- stable owner ordering
- stable pet-name ordering
- no duplicate owners
- same observable projection across JDBC, JPA, and Spring Data JPA

## validationCommands

- `git diff --check`
- `$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd -Dtest=*OwnerSearch* test`

## validationResults

- `git diff --check`: passed
- `JdbcOwnerSearchContractTests`: 6 tests, 0 failures, 0 errors, 0 skipped
- `JpaOwnerSearchContractTests`: 6 tests, 0 failures, 0 errors, 0 skipped
- `SpringDataJpaOwnerSearchContractTests`: 6 tests, 0 failures, 0 errors, 0 skipped
- total: 18 tests, 0 failures, 0 errors, 0 skipped

## outputHead

pending local commit

## outcome

adapter_contract_baseline_recorded

## stopReasons

none

## receiptRef

`threshold/receipts/owner-search-p2-02-adapter-contract-20260717T130038Z.json`

## nonClaims

- This phase does not claim query-count improvement.
- This phase does not change production behavior.
- This phase does not introduce the new Owner Search read model or port.
- This phase does not claim architecture-rule coverage.
