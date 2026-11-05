# Owner Search Compatibility Path V0.1

phaseId: P2-10
inputHead: 8087dfcd68dba6736e99a066b399b1d4a1ea2aa3
inputDigest: p2-10-authority-activation
allowedPaths:
- src/main/java/org/springframework/samples/petclinic/**
- src/test/java/org/springframework/samples/petclinic/**
- src/main/resources/spring/**
- threshold/docs/**
- threshold/receipts/**
- threshold/lease-state/**
- threshold/leases/**

## Expected Effect

Dokumentieren und pruefen, wie der bestehende `ClinicService.findOwnerByLastName(String)`-Pfad nach der P2-09
Controller-Migration erhalten bleibt. Keine Entfernung der oeffentlichen Java-API.

## Compatibility Method

`ClinicService.findOwnerByLastName(String)` bleibt unveraendert als Legacy-Fassade erhalten:

- Interface: `src/main/java/org/springframework/samples/petclinic/service/ClinicService.java`
- Implementation: `src/main/java/org/springframework/samples/petclinic/service/ClinicServiceImpl.java`
- Delegate: `OwnerRepository.findByLastName(lastName)`
- Return type: `Collection<Owner>`

## Remaining Callers

Produktionscode:

- Keine Web-Controller-Aufrufer nach P2-09.

Test- und Contract-Code:

- `AbstractClinicServiceTests`
- `AbstractOwnerSearchContractTests`
- `AbstractOwnerSearchQueryMeasurementTests`

Diese Tests halten den alten Entity-basierten Servicevertrag fest. Sie sind absichtlich nicht auf `SearchOwners`
umgebogen, weil sie einen anderen Vertrag pruefen als die neue Owner-Search-Read-Model-Suche.

## Delegation Decision

Keine Delegation von `ClinicService.findOwnerByLastName` zu `SearchOwners` oder `OwnerSearchQuery`.

Begruendung:

- `ClinicService.findOwnerByLastName` liefert vollstaendige `Owner`-Entities.
- `SearchOwners` liefert `OwnerListItem`-Read-Models fuer die Suchergebnisliste.
- Eine Rueckprojektion von `OwnerListItem` nach `Owner` waere ein semantischer Scheinvertrag.
- Eine Delegation auf den neuen Port wuerde bestehende Service-Contract-Tests und nicht migrierte Aufrufer nicht
  gleichwertig bedienen.

## Deprecation Status

Nicht deprecated in P2-10.

Begruendung:

- Die Methode ist noch Teil des oeffentlichen `ClinicService`-Interface.
- Service-Contract-Tests nutzen sie weiter als Kompatibilitaetsanker.
- Eine Annotation oder API-Markierung soll erst erfolgen, wenn alle produktiven und testseitigen Entity-Search-Contracts
  explizit ersetzt oder als Legacy-Vertrag akzeptiert sind.

## Planned Removal Condition

Entfernung oder Deprecation erst nach einer separaten, autorisierten Phase, wenn:

- keine produktiven Aufrufer verbleiben;
- Service-Contract-Tests nicht mehr auf Entity-basierte Owner-Suche angewiesen sind oder bewusst als Legacy-Tests
  ersetzt wurden;
- alle drei Persistence-Profile weiterhin gruen sind;
- Owner-Details-, Pet- und Visit-Flows ihre eigenen Fetch-Vertraege behalten;
- ein expliziter Grant fuer API-Entfernung oder Deprecation aktiv ist.

## Validation Commands

- git diff --check
- .\mvnw.cmd "-Dtest=ClinicServiceJdbcTests,ClinicServiceJpaTests,ClinicServiceSpringDataJpaTests" test
- .\mvnw.cmd -Dtest=OwnerControllerTests test

## Validation Results

- `git diff --check`: pass
- `.\mvnw.cmd "-Dtest=ClinicServiceJdbcTests,ClinicServiceJpaTests,ClinicServiceSpringDataJpaTests" test`: pass,
  33 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd -Dtest=OwnerControllerTests test`: pass, 14 Tests, 0 Fehler, 0 Errors, 0 skipped

## Outcome

validated_local_change_pending_commit

## Stop Reasons

Keine zum Zeitpunkt der Erstellung.
