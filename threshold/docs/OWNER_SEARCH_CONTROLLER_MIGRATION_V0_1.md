# Owner Search Controller Migration V0.1

phaseId: P2-09
inputHead: 4235f1194506634868fb55318a12092d5fd431b0
inputDigest: local-p2-09-authority-activation
allowedPaths:
- src/main/java/org/springframework/samples/petclinic/**
- src/test/java/org/springframework/samples/petclinic/**
- src/main/resources/spring/**
- threshold/docs/**
- threshold/receipts/**
- threshold/lease-state/**
- threshold/leases/**

## Erwarteter Effekt

Ausschliesslich die Owner-Suche im Web-Controller auf den `SearchOwners` Use Case migrieren. Owner-Create, Owner-Update,
Owner-Details, Pet-, Visit- und Vet-Flows bleiben auf den bestehenden Pfaden.

## Geaenderte Pfade

- src/main/java/org/springframework/samples/petclinic/owner/api/OwnerListItem.java
- src/main/java/org/springframework/samples/petclinic/owner/application/SearchOwners.java
- src/main/java/org/springframework/samples/petclinic/web/OwnerController.java
- src/main/resources/spring/business-config.xml
- src/main/webapp/WEB-INF/jsp/owners/ownersList.jsp
- src/test/java/org/springframework/samples/petclinic/web/OwnerControllerTests.java
- src/test/java/org/springframework/samples/petclinic/web/WebTestMocks.java
- src/test/resources/spring/mvc-test-config.xml
- threshold/docs/OWNER_SEARCH_CONTROLLER_MIGRATION_V0_1.md
- threshold/receipts/owner-search-p2-09-controller-migration-20260717T191700Z.json
- threshold/lease-state/current-run.json

## Implementierung

`OwnerController.processFindForm` ruft fuer die Suchergebnisliste jetzt `SearchOwners.searchByLastName(...)` auf und legt
bei mehreren Treffern `List<OwnerListItem>` als `selections` ins Model. Die 0/1/>1-Semantik bleibt erhalten:

- 0 Treffer: `owners/findOwners` mit `notFound` auf `owner.lastName`
- 1 Treffer: Redirect nach `redirect:/owners/{id}`
- mehrere Treffer: `owners/ownersList`

Die JSP liest fuer die Ergebnisliste `petNames` statt vollstaendiger `pets`. `OwnerListItem` enthaelt JavaBean-kompatible
Getter, damit die vorhandene JSP-Property-Syntax stabil bleibt. `SearchOwners` wird als Spring-Service gescannt.

## Validierungsbefehle

- git diff --check
- .\mvnw.cmd -Dtest=OwnerControllerTests test
- .\mvnw.cmd "-Dtest=OwnerControllerTests,CrashControllerTests,PetControllerTests,VetControllerTests" test
- .\mvnw.cmd -Dtest=*OwnerSearch* test
- .\mvnw.cmd test
- .\mvnw.cmd "-Dspring.profiles.active=jdbc" test
- .\mvnw.cmd "-Dspring.profiles.active=jpa" test
- .\mvnw.cmd "-Dspring.profiles.active=spring-data-jpa" test

## Validierungsergebnisse

- `git diff --check`: pass
- `.\mvnw.cmd -Dtest=OwnerControllerTests test`: pass, 14 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd "-Dtest=OwnerControllerTests,CrashControllerTests,PetControllerTests,VetControllerTests" test`: pass, 24 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd -Dtest=*OwnerSearch* test`: pass, 33 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd test`: pass, 119 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd "-Dspring.profiles.active=jdbc" test`: pass, 119 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd "-Dspring.profiles.active=jpa" test`: pass, 119 Tests, 0 Fehler, 0 Errors, 0 skipped
- `.\mvnw.cmd "-Dspring.profiles.active=spring-data-jpa" test`: pass, 119 Tests, 0 Fehler, 0 Errors, 0 skipped

## Evidenz

behaviorParityResult: pass fuer charakterisierte Controller-Suche.
profileParityVerified: true fuer jdbc, jpa und spring-data-jpa Testmatrix.
queryBudgetResult: keine neue Query-Messung in P2-09; Adapter-Projektionspfade aus P2-06 bis P2-08 bleiben unveraendert.
architectureEvidence: Web-Controller haengt nur von `SearchOwners` ab, nicht von konkreten Persistence-Adaptern.

## Outcome

validated_local_change_pending_commit

## Stop Reasons

Keine zum Zeitpunkt der Erstellung.
