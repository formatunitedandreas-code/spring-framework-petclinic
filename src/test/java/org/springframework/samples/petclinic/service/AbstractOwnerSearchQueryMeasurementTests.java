package org.springframework.samples.petclinic.service;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Collection;

import org.hibernate.LazyInitializationException;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.samples.petclinic.model.Owner;
import org.springframework.samples.petclinic.model.Pet;

abstract class AbstractOwnerSearchQueryMeasurementTests {

    @Autowired
    protected ClinicService clinicService;

    @Autowired
    private SqlStatementCounter sqlStatementCounter;

    @Test
    void measuresSingleOwnerSearchBaseline() {
        OwnerSearchMeasurement measurement = measure("Franklin");

        assertThat(measurement.resultCount()).isEqualTo(1);
        assertThat(measurement.loadedOwnerCount()).isEqualTo(1);
        assertThat(measurement.loadedPetCount()).isEqualTo(1);
        assertThat(measurement.loadedVisitCount()).isZero();
        assertThat(measurement.duplicateResultCount()).isZero();
        assertThat(measurement.queryCount()).isEqualTo(expectedSingleOwnerQueryCount());
    }

    @Test
    void measuresAllSeededOwnersSearchBaseline() {
        OwnerSearchMeasurement measurement = measure("");

        assertThat(measurement.resultCount()).isEqualTo(10);
        assertThat(measurement.loadedOwnerCount()).isEqualTo(10);
        assertThat(measurement.loadedPetCount()).isEqualTo(13);
        assertThat(measurement.loadedVisitCount()).isEqualTo(expectedAllOwnersLoadedVisitCount());
        assertThat(measurement.duplicateResultCount()).isZero();
        assertThat(measurement.queryCount()).isEqualTo(expectedAllOwnersQueryCount());
    }

    protected abstract int expectedSingleOwnerQueryCount();

    protected abstract int expectedAllOwnersQueryCount();

    protected int expectedAllOwnersLoadedVisitCount() {
        return 0;
    }

    private OwnerSearchMeasurement measure(String lastName) {
        this.sqlStatementCounter.reset();
        Collection<Owner> owners = this.clinicService.findOwnerByLastName(lastName);
        int queryCount = this.sqlStatementCounter.count();
        int loadedPetCount = owners.stream()
            .mapToInt(owner -> owner.getPets().size())
            .sum();
        int loadedVisitCount = owners.stream()
            .flatMap(owner -> owner.getPets().stream())
            .mapToInt(this::loadedVisitCount)
            .sum();
        long duplicateResultCount = owners.size() - owners.stream()
            .map(Owner::getId)
            .distinct()
            .count();
        return new OwnerSearchMeasurement(
            queryCount,
            owners.size(),
            owners.size(),
            loadedPetCount,
            loadedVisitCount,
            Math.toIntExact(duplicateResultCount)
        );
    }

    private int loadedVisitCount(Pet pet) {
        try {
            return pet.getVisits().size();
        }
        catch (LazyInitializationException ex) {
            return 0;
        }
    }

    private record OwnerSearchMeasurement(
        int queryCount,
        int resultCount,
        int loadedOwnerCount,
        int loadedPetCount,
        int loadedVisitCount,
        int duplicateResultCount
    ) {
    }
}
