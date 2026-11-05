# Owner Search Query Baseline V0.1

runId: owner-search-p2-03-query-baseline-20260717T133536Z

## phaseId

P2-03 query_measurement_baseline

## inputHead

264ec6501cc5410b7024e77ae9b97e3c9d2276c1

## inputDigest

- branch: `agent/owner-search-query-baseline`
- origin/main: `7a4e871184071d9affda8224a5cc66a0f7665d30`
- active grant: `p2-03-owner-search-query-measurement-baseline`
- active lane: `product_refactor`

## allowedPaths

- `src/test/java/org/springframework/samples/petclinic/**`
- `threshold/docs/**`
- `threshold/receipts/**`
- active Authority runtime files under `threshold/lease-state/**` and `threshold/leases/**`

## expectedEffect

Add test-local SQL statement counting for the current Owner Search path without changing production logic.

## changedPaths

- `src/test/java/org/springframework/samples/petclinic/service/SqlStatementCounter.java`
- `src/test/java/org/springframework/samples/petclinic/service/SqlCountingDataSourcePostProcessor.java`
- `src/test/java/org/springframework/samples/petclinic/service/owner-search-query-counting-config.xml`
- `src/test/java/org/springframework/samples/petclinic/service/AbstractOwnerSearchQueryMeasurementTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/JdbcOwnerSearchQueryMeasurementTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/JpaOwnerSearchQueryMeasurementTests.java`
- `src/test/java/org/springframework/samples/petclinic/service/SpringDataJpaOwnerSearchQueryMeasurementTests.java`
- `threshold/docs/OWNER_SEARCH_QUERY_BASELINE_V0_1.md`
- `threshold/receipts/owner-search-p2-03-query-baseline-20260717T133536Z.json`

## measurementMethod

Test-local `DataSource` proxy increments a counter whenever a JDBC `Statement`, `PreparedStatement`, or `CallableStatement` is created. The counter is reset immediately before `ClinicService.findOwnerByLastName(...)`.

Loaded entity counts are observed from the returned Owner graph:

- owner count: returned owners
- pet count: `owner.getPets().size()`
- visit count: `pet.getVisits().size()`

## queryCountsBefore

| profile | search | resultCount | queryCount | loadedOwnerCount | loadedPetCount | loadedVisitCount | duplicateResultCount |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| jdbc | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| jdbc | empty/all seeded owners | 10 | 21 | 10 | 13 | 4 | 0 |
| jpa | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| jpa | empty/all seeded owners | 10 | 20 | 10 | 13 | 4 | 0 |
| spring-data-jpa | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| spring-data-jpa | empty/all seeded owners | 10 | 20 | 10 | 13 | 4 | 0 |

## hypothesis

`jdbcOwnerSearchComplexity=1_plus_2N` is confirmed for the current seeded baseline:

- `N=1`: `1 + 2N = 3`
- `N=10`: `1 + 2N = 21`

## validationCommands

- `git diff --check`
- `$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd -Dtest=*OwnerSearchQueryMeasurement* test`

## validationResults

- `git diff --check`: passed
- `JdbcOwnerSearchQueryMeasurementTests`: 2 tests, 0 failures, 0 errors, 0 skipped
- `JpaOwnerSearchQueryMeasurementTests`: 2 tests, 0 failures, 0 errors, 0 skipped
- `SpringDataJpaOwnerSearchQueryMeasurementTests`: 2 tests, 0 failures, 0 errors, 0 skipped
- total: 6 tests, 0 failures, 0 errors, 0 skipped

## outputHead

pending local commit

## outcome

query_baseline_recorded

## stopReasons

none

## receiptRef

`threshold/receipts/owner-search-p2-03-query-baseline-20260717T133536Z.json`

## nonClaims

- This phase does not optimize queries.
- This phase does not introduce a read model or port.
- This phase does not claim target query budget compliance.
- This phase does not claim visit materialization has been removed.
