# Owner Search Architecture Rules V0.1

phaseId: P2-11
inputHead: 4031228a8d86566097d0f933085e03c0d7d2a7a4
inputDigest: p2-11-authority-activation

## Entscheidung

outcome: packet_preparation_only

ArchUnit ist im Projekt nicht vorhanden. Der aktive P2-11-Grant erlaubt keine neue Maven-Test-Dependency ohne
ausdrueckliche Dependency-Freigabe. Deshalb werden keine aktiven ArchUnit-Tests und keine `pom.xml`-Aenderung
materialisiert.

## Statische Readout-Pruefung

Quelle: Import- und Paket-Scan unter `src/main/java/org/springframework/samples/petclinic`.

- web does not depend on jdbc adapter: pass
- web does not depend on jpa adapter: pass
- web does not depend on spring-data adapter: pass
- application does not depend on web: pass
- application does not depend on persistence frameworks: pass
- ports do not depend on adapters: pass
- adapters may implement ports: pass
- adapter packages do not depend on web: pass
- owner feature packages are cycle-free: no cycle observed by import scan

## Observed Dependencies

- `OwnerController` depends on `SearchOwners`, `OwnerListItem`, `ClinicService`, MVC types and domain `Owner`.
- `SearchOwners` depends on `OwnerSearchQuery` and `OwnerListItem`.
- `OwnerSearchQuery` depends only on `OwnerListItem`.
- JDBC/JPA/Spring Data owner-search adapters implement `OwnerSearchQuery`.
- Persistence framework imports are confined to adapter/repository/model areas, not owner application or port.

## Executable Proposal

If a separate dependency grant permits ArchUnit, add a test-only dependency and materialize a focused test such as:

```java
package org.springframework.samples.petclinic.owner;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.library.dependencies.SlicesRuleDefinition.slices;

@AnalyzeClasses(
    packages = "org.springframework.samples.petclinic",
    importOptions = ImportOption.DoNotIncludeTests.class
)
class OwnerFeatureArchitectureTests {

    @ArchTest
    static final ArchRule web_does_not_depend_on_owner_adapters =
        noClasses().that().resideInAPackage("..web..")
            .should().dependOnClassesThat().resideInAnyPackage("..owner.adapter..");

    @ArchTest
    static final ArchRule application_does_not_depend_on_web_or_persistence =
        noClasses().that().resideInAPackage("..owner.application..")
            .should().dependOnClassesThat().resideInAnyPackage(
                "..web..",
                "jakarta.persistence..",
                "org.springframework.data..",
                "org.springframework.jdbc.."
            );

    @ArchTest
    static final ArchRule ports_do_not_depend_on_adapters =
        noClasses().that().resideInAPackage("..owner.port..")
            .should().dependOnClassesThat().resideInAPackage("..owner.adapter..");

    @ArchTest
    static final ArchRule adapters_do_not_depend_on_web =
        noClasses().that().resideInAPackage("..owner.adapter..")
            .should().dependOnClassesThat().resideInAPackage("..web..");

    @ArchTest
    static final ArchRule owner_feature_packages_are_cycle_free =
        slices().matching("org.springframework.samples.petclinic.owner.(*)..")
            .should().beFreeOfCycles();
}
```

## Validation Commands

- `rg -i "archunit|architecture" pom.xml src/test/java threshold/docs`
- `rg "^import ..." src/main/java/org/springframework/samples/petclinic -n`
- `git diff --check`

## Validation Results

- ArchUnit dependency scan: not present
- Static import scan: pass for proposed owner-feature boundaries
- `git diff --check`: pass

## Non-Claims

- No active architecture test was added.
- No dependency was added.
- No enforcement claim beyond the static readout is made.
