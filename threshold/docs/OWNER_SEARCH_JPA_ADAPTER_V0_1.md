# Owner Search JPA Adapter V0.1

phaseId: P2-07
inputHead: 97c737fa5a36e8cc89c41b0bb6e8511daab5002a
inputDigest: local-p2-07-authority-activation
allowedPaths:
- src/main/java/org/springframework/samples/petclinic/**
- src/test/java/org/springframework/samples/petclinic/**
- src/main/resources/spring/**
- threshold/docs/**
- threshold/receipts/**
- threshold/lease-state/**

## Expected Effect

Materialize the JPA implementation of `OwnerSearchQuery` for the owner-search result list.

## Changed Paths

- src/main/java/org/springframework/samples/petclinic/owner/adapter/jpa/JpaOwnerSearchQuery.java
- src/main/resources/spring/business-config.xml
- src/test/java/org/springframework/samples/petclinic/service/JpaOwnerSearchQueryTests.java
- threshold/docs/OWNER_SEARCH_JPA_ADAPTER_V0_1.md
- threshold/receipts/owner-search-p2-07-jpa-adapter-20260717T171000Z.json
- threshold/lease-state/current-run.json

## Implementation

The JPA adapter uses a scalar JPQL query from `Owner` to `pet.name` and groups rows into immutable
`OwnerListItem` values. The query does not fetch `Visit` or `PetType` entities.

## Validation Commands

- git diff --check
- .\mvnw.cmd -Dtest=JpaOwnerSearchQueryTests test
- .\mvnw.cmd -Dtest=*OwnerSearch* test
- .\mvnw.cmd test

## Validation Results

- `git diff --check`: pass
- `.\mvnw.cmd -Dtest=JpaOwnerSearchQueryTests test`: pass, 3 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd -Dtest=*OwnerSearch* test`: pass, 30 tests, 0 failures, 0 errors, 0 skipped
- `.\mvnw.cmd test`: pass, 116 tests, 0 failures, 0 errors, 0 skipped

JPA owner-search projection query count:

- exact prefix `Davis`: 1 query
- empty string / all seeded owners: 1 query
- multiple pets `Coleman`: 1 query

Observed generated SQL selects owner list fields and `pets.name`; it does not select from `visits` or `types`.

## Outcome

validated_local_change_pending_commit

## Stop Reasons

None at creation time.
