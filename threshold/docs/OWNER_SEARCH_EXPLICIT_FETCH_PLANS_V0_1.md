# Owner Search Explicit Fetch Plans V0.1

phaseId: P2-12
inputHead: 16ca87d0a69b079c20351a048d7b082ca9b057f2
inputDigest: p2-12-authority-activation
candidateClass: owner_search_explicit_fetch_plans
outcome: local_validation_green_pending_commit

## Summary

`Pet.visits` no longer uses global eager fetching. JPA and Spring Data JPA now use explicit fetch plans on detail/context reads that render visits, while owner search list paths avoid visit materialization.

## Architecture Before

- `Pet.visits` was mapped as `fetch = FetchType.EAGER`.
- Owner search entity paths for JPA/Spring Data could materialize visits indirectly through the pet collection.
- Owner details, pet edit and visit create paths relied on the global eager visit mapping.

## Architecture After

- `Pet.visits` uses default lazy collection loading.
- JPA `OwnerRepository.findById` explicitly fetches owner pets, pet types and pet visits.
- JPA `PetRepository.findById` explicitly fetches pet owner, pet type and pet visits.
- Spring Data JPA `OwnerRepository.findById` explicitly fetches owner pets, pet types and pet visits.
- Spring Data JPA `PetRepository.findById` explicitly fetches pet owner, pet type and pet visits.
- Owner search read-model adapters remain explicit projections without visit columns.
- Legacy JPA/Spring Data owner entity search keeps pets visible but does not force visits.

## Query Evidence

Owner search projection query budget remains unchanged:

- JDBC OwnerSearchQuery: 1 query per search.
- JPA OwnerSearchQuery: 1 query per search.
- Spring Data JPA OwnerSearchQuery: 1 query per search.

Legacy entity search measurement after P2-12:

- JDBC single owner: 3 queries, 0 loaded visits for `Franklin`.
- JDBC all owners: 21 queries, 4 loaded visits.
- JPA single owner: 2 queries, 0 loaded visits.
- JPA all owners: 7 queries, 0 materialized visits.
- Spring Data JPA single owner: 2 queries, 0 loaded visits.
- Spring Data JPA all owners: 7 queries, 0 materialized visits.

## Validation Commands

- `git fetch origin`
- `git status --short`
- `git branch --show-current`
- `git rev-parse HEAD`
- `git rev-parse origin/main`
- `.\mvnw.cmd -Dtest=*OwnerSearch* test`
- `.\mvnw.cmd -Dtest=OwnerControllerTests,PetControllerTests,VisitControllerTests test`
- `.\mvnw.cmd -Dspring.profiles.active=jdbc test`
- `.\mvnw.cmd -Dspring.profiles.active=jpa test`
- `.\mvnw.cmd -Dspring.profiles.active=spring-data-jpa test`
- `git diff --check`
- `.\mvnw.cmd test`

## Validation Results

- `*OwnerSearch*`: pass, 33 tests, 0 failures, 0 errors, 0 skipped.
- Owner/Pet/Visit controller tests: pass, 24 tests, 0 failures, 0 errors, 0 skipped.
- JDBC profile: pass, 119 tests, 0 failures, 0 errors, 0 skipped.
- JPA profile: pass, 119 tests, 0 failures, 0 errors, 0 skipped.
- Spring Data JPA profile: pass, 119 tests, 0 failures, 0 errors, 0 skipped.
- `git diff --check`: pass.
- Default test: pass, 119 tests, 0 failures, 0 errors, 0 skipped.

## Known Limitations

- No browser-level manual UI validation was performed.
- Architecture rules remain P2-11 readout-only; no active ArchUnit dependency was added in this slice.
- JDBC repository behavior was intentionally not changed in P2-12.

## Non-Claims

- No production readiness claim.
- No security validation claim.
- No compliance claim.
- No upstream readiness claim.
- No merge authority claim.
