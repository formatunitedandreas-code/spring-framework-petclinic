# Phase 2 Owner Search P2-10 Authority Active V0.1

phaseId: P2-10
runId: p2-10-owner-search-compatibility-path-20260717T194000Z
branch: agent/owner-search-compatibility-path
sourceHead: 8087dfcd68dba6736e99a066b399b1d4a1ea2aa3
originMain: 8087dfcd68dba6736e99a066b399b1d4a1ea2aa3

## Entscheidung

continue_to_compatibility_path

## Scope

P2-10 darf den bestehenden Owner-Search-Kompatibilitaetspfad pruefen und dokumentieren. Oeffentliche Java-APIs werden
nicht entfernt. Eine Delegation von `ClinicService.findOwnerByLastName` auf den neuen `OwnerSearchQuery`-Port ist nicht
automatisch zugelassen, weil der alte Vertrag vollstaendige `Owner`-Entities liefert, der neue Port aber nur
`OwnerListItem`-Read-Models.
