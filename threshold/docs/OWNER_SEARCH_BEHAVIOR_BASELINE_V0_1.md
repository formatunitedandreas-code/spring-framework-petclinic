# Owner Search Behavior Baseline V0.1

runId: owner-search-p2-01-behavior-baseline-20260717T123037Z

## phaseId

P2-01 architecture_and_behavior_baseline

## inputHead

00ab52faa60f82115ac034be8ead6a6c0e92892e

## inputDigest

- branch: `main`
- productSourceHead: `04f7e344e51ed6c75e9e3062ebc8ee7fa9415b1c`
- origin/main: `04f7e344e51ed6c75e9e3062ebc8ee7fa9415b1c`
- inputHead...origin/main: `1 0`
- active grant: `p2-01-owner-search-product-refactor`
- active lane: `product_refactor`

## allowedPaths

- `src/test/java/org/springframework/samples/petclinic/**`
- `threshold/docs/**`
- `threshold/receipts/**`
- active Authority runtime files under `threshold/lease-state/**` and `threshold/leases/**`

## expectedEffect

Add characterization tests for the existing Owner Search UI/controller behavior without changing production logic.

## changedPaths

- `src/test/java/org/springframework/samples/petclinic/web/OwnerControllerTests.java`
- `threshold/docs/OWNER_SEARCH_BEHAVIOR_BASELINE_V0_1.md`
- `threshold/receipts/owner-search-p2-01-behavior-baseline-20260717T123037Z.json`

Authority activation files already present before this phase:

- `threshold/leases/current.yaml`
- `threshold/lease-state/current-run.json`
- `threshold/docs/PHASE_2_OWNER_SEARCH_P2_01_AUTHORITY_ACTIVE_V0_1.md`
- `threshold/receipts/owner-search-p2-01-authority-activation-20260717T102509Z.json`

## behaviorCaptured

- Empty or missing `lastName` is normalized to `""`.
- Parameterless `GET /owners` calls `findOwnerByLastName("")`.
- Multiple results render `owners/ownersList`.
- Multiple result model attribute remains `selections`.
- Multiple result ordering remains the service result ordering.
- Owner id, first name, last name, address, city, and telephone remain present in the model.
- Pet names remain visible through `owner.getPets()` for the list view contract.
- Pet-name ordering follows the current Owner model ordering.
- One result redirects to `/owners/{ownerId}`.
- No result returns `owners/findOwners`.
- No result adds a `notFound` validation error on `owner.lastName`.
- Existing create, update, details, and find-form view names remain covered by existing tests.

## validationCommands

- `git diff --check`
- `$env:JAVA_HOME='C:\Program Files\Java\jdk-17'; .\mvnw.cmd -Dtest=OwnerControllerTests test`

## validationResults

- `git diff --check`: passed
- `OwnerControllerTests`: passed
- tests run: 14
- failures: 0
- errors: 0
- skipped: 0

## outputHead

0c9421c69107398ebe2460321bf2db758dc43b43

## outcome

behavior_baseline_recorded

## stopReasons

none

## receiptRef

`threshold/receipts/owner-search-p2-01-behavior-baseline-20260717T123037Z.json`

## nonClaims

- This phase does not claim query-count improvement.
- This phase does not claim adapter parity.
- This phase does not claim architecture-rule coverage.
- This phase does not change production behavior.
