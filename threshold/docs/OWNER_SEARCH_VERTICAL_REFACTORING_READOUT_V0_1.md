# Owner Search Vertical Refactoring Readout V0.1

sourceHead: 04f7e344e51ed6c75e9e3062ebc8ee7fa9415b1c
finalHead: f5b6c63eabe4b34af67cc8d38cd0df32373a58bf
phaseId: P2-14
candidateClass: owner_search_before_after_readout
outcome: local_readout_recorded_pending_commit

## changedFiles

- `src/main/java/org/springframework/samples/petclinic/owner/api/OwnerListItem.java`
- `src/main/java/org/springframework/samples/petclinic/owner/application/SearchOwners.java`
- `src/main/java/org/springframework/samples/petclinic/owner/port/OwnerSearchQuery.java`
- `src/main/java/org/springframework/samples/petclinic/owner/adapter/jdbc/JdbcOwnerSearchQuery.java`
- `src/main/java/org/springframework/samples/petclinic/owner/adapter/jpa/JpaOwnerSearchQuery.java`
- `src/main/java/org/springframework/samples/petclinic/owner/adapter/springdata/SpringDataJpaOwnerSearchQuery.java`
- `src/main/java/org/springframework/samples/petclinic/owner/adapter/springdata/SpringDataJpaOwnerSearchRows.java`
- `src/main/java/org/springframework/samples/petclinic/web/OwnerController.java`
- `src/main/java/org/springframework/samples/petclinic/model/Pet.java`
- `src/main/java/org/springframework/samples/petclinic/repository/jpa/JpaOwnerRepositoryImpl.java`
- `src/main/java/org/springframework/samples/petclinic/repository/jpa/JpaPetRepositoryImpl.java`
- `src/main/java/org/springframework/samples/petclinic/repository/springdatajpa/SpringDataOwnerRepository.java`
- `src/main/java/org/springframework/samples/petclinic/repository/springdatajpa/SpringDataPetRepository.java`
- `src/main/resources/spring/business-config.xml`
- `src/main/webapp/WEB-INF/jsp/owners/ownersList.jsp`
- targeted owner-search test and evidence files under `src/test/java/...` and `threshold/**`

## architectureBefore

- Owner search web flow depended on `ClinicService.findOwnerByLastName(String)` and returned `Collection<Owner>`.
- Search results were rendered from Owner entities and pet collections.
- No dedicated owner-search read model, use case, or query port existed.
- JDBC owner search followed the confirmed `1 + 2N` baseline pattern for seeded data.
- JPA and Spring Data JPA owner search materialized owner/pet graphs with visit loading still reachable through the eager `Pet.visits` mapping.

## architectureAfter

- Owner search now flows through `OwnerController -> SearchOwners -> OwnerSearchQuery -> {jdbc,jpa,spring-data-jpa} adapter`.
- `OwnerListItem` is the immutable read model for the list view and carries only `id`, `firstName`, `lastName`, `address`, `city`, `telephone`, and `petNames`.
- JDBC, JPA, and Spring Data JPA each implement an explicit owner-search projection that excludes visits from the list path.
- `ClinicService.findOwnerByLastName(String)` remains as the compatibility path for legacy entity-based contracts and service tests.
- `Pet.visits` is no longer globally eager; JPA and Spring Data JPA now use explicit fetch plans for owner details and pet/visit context reads.
- Architecture enforcement remains readout-only from P2-11; no active ArchUnit dependency was admitted.

## behaviorBaseline

- Empty or missing `lastName` is normalized to `""`.
- No result returns `owners/findOwners` with `notFound` on `owner.lastName`.
- One result redirects to `/owners/{ownerId}`.
- Multiple results render `owners/ownersList`.
- Owner ordering remains stable.
- Pet names remain visible in the list.
- Owner list fields remain unchanged.
- HTML view names and redirect paths remain unchanged.

## behaviorAfter

- P2-13 re-validation confirms the same 0/1/>1 flow, identical view names, identical redirect shape, stable ordering, and visible pet names through the `OwnerListItem.petNames` projection.
- No intentional visible owner-search behavior change was introduced.

## queryCountsBefore

Entity-search baseline from P2-03:

| profile | search | resultCount | queryCount | loadedOwnerCount | loadedPetCount | loadedVisitCount | duplicateResultCount |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| jdbc | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| jdbc | empty/all seeded owners | 10 | 21 | 10 | 13 | 4 | 0 |
| jpa | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| jpa | empty/all seeded owners | 10 | 20 | 10 | 13 | 4 | 0 |
| spring-data-jpa | `Franklin` | 1 | 3 | 1 | 1 | 0 | 0 |
| spring-data-jpa | empty/all seeded owners | 10 | 20 | 10 | 13 | 4 | 0 |

## queryCountsAfter

Owner-search projection path after P2-06 to P2-12:

| profile | search | queryCount | visitMaterialization |
| --- | --- | ---: | --- |
| jdbc | exact prefix / empty / multiple pets | 1 | no visit select in projection SQL |
| jpa | exact prefix / empty / multiple pets | 1 | no visit or type select in projection SQL |
| spring-data-jpa | exact prefix / empty / multiple pets | 1 | no visit or type select in projection SQL |

Legacy entity-search compatibility path after P2-12:

| profile | search | queryCount | loadedVisitCount |
| --- | --- | ---: | ---: |
| jdbc | `Franklin` | 3 | 0 |
| jdbc | empty/all seeded owners | 21 | 4 |
| jpa | `Franklin` | 2 | 0 |
| jpa | empty/all seeded owners | 7 | 0 |
| spring-data-jpa | `Franklin` | 2 | 0 |
| spring-data-jpa | empty/all seeded owners | 7 | 0 |

## loadedEntitiesBefore

- Owner entities: 1 / 10 depending on search case
- Pet entities: 1 / 13 depending on search case
- Visit entities: up to 4 on the seeded all-owners path for all three profiles

## loadedEntitiesAfter

- Owner-search projection path: no Owner/Pet/Visit entity contract is exposed to the UI list; adapters emit `OwnerListItem` values only
- Owner-search visit materialization: 0 on the read-model path for all three adapters
- Legacy entity-search compatibility path:
  - JDBC still materializes the seeded legacy entity graph as before
  - JPA and Spring Data JPA no longer materialize visits on owner-search entity compatibility reads

Inference note: the projection-path entity statement is derived from the adapter SQL/JPQL evidence and the absence of visit/type fields in the read-model contract.

## adapterParity

- JDBC, JPA, and Spring Data JPA satisfy the common owner-search contract.
- Stable owner ordering, stable pet-name ordering, no duplicate owners, owners without pets, and owners with multiple pets were covered by the contract suite.
- Same observable list projection across adapters was validated.

## tests

- `git diff --check`: pass
- `.\mvnw.cmd -Dtest=*OwnerSearch* test`: pass, 33 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd -Dtest=OwnerControllerTests,PetControllerTests,VisitControllerTests test`: pass, 24 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd -Dspring.profiles.active=jdbc test`: pass, 119 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd -Dspring.profiles.active=jpa test`: pass, 119 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd -Dspring.profiles.active=spring-data-jpa test`: pass, 119 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd test`: pass, 119 tests, 0 failures, 0 errors, 0 skipped

## knownLimitations

- No browser-level manual UI verification was performed.
- Architecture rules were documented but not enforced by an active ArchUnit dependency.
- Query before/after evidence combines direct measurement for the legacy path with projection-query evidence from adapter-specific tests and observed generated SQL.
- JDBC compatibility-path query complexity remains `1 + 2N`; the optimization target was achieved on the dedicated owner-search projection path, not by rewriting the legacy entity service contract.

## remainingRisks

- Future callers could accidentally reintroduce entity-based owner-search list rendering if they bypass `SearchOwners`.
- The compatibility path remains intentionally present, so legacy query behavior and the read-model path can drift unless both continue to be tested.
- The absence of active architecture enforcement means package-boundary regressions would currently be caught by review/tests rather than a dedicated architecture test.

## nonClaims

- No production readiness claim
- No security validation claim
- No compliance claim
- No upstream readiness claim
- No publication or deployment claim
