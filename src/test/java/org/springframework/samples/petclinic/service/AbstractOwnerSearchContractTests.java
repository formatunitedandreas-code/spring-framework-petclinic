package org.springframework.samples.petclinic.service;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Collection;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.samples.petclinic.model.Owner;
import org.springframework.samples.petclinic.model.Pet;
import org.springframework.transaction.annotation.Transactional;

abstract class AbstractOwnerSearchContractTests {

    @Autowired
    protected ClinicService clinicService;

    @Test
    void searchByExactPrefixReturnsMatchingOwners() {
        List<OwnerSearchProjection> owners = search("Davis");

        assertThat(owners).containsExactly(
            owner(2, "Betty", "Davis", "638 Cardinal Ave.", "Sun Prairie", "6085551749", "Basil"),
            owner(4, "Harold", "Davis", "563 Friendly St.", "Windsor", "6085553198", "Iggy")
        );
    }

    @Test
    void searchWithEmptyStringReturnsAllSeededOwnersInStableOrder() {
        assertThat(search("")).containsExactly(
            owner(1, "George", "Franklin", "110 W. Liberty St.", "Madison", "6085551023", "Leo"),
            owner(2, "Betty", "Davis", "638 Cardinal Ave.", "Sun Prairie", "6085551749", "Basil"),
            owner(3, "Eduardo", "Rodriquez", "2693 Commerce St.", "McFarland", "6085558763", "Jewel", "Rosy"),
            owner(4, "Harold", "Davis", "563 Friendly St.", "Windsor", "6085553198", "Iggy"),
            owner(5, "Peter", "McTavish", "2387 S. Fair Way", "Madison", "6085552765", "George"),
            owner(6, "Jean", "Coleman", "105 N. Lake St.", "Monona", "6085552654", "Max", "Samantha"),
            owner(7, "Jeff", "Black", "1450 Oak Blvd.", "Monona", "6085555387", "Lucky"),
            owner(8, "Maria", "Escobito", "345 Maple St.", "Madison", "6085557683", "Mulligan"),
            owner(9, "David", "Schroeder", "2749 Blackhawk Trail", "Madison", "6085559435", "Freddy"),
            owner(10, "Carlos", "Estaban", "2335 Independence La.", "Waunakee", "6085555487", "Lucky", "Sly")
        );
    }

    @Test
    void searchWithNoResultsReturnsEmptyCollection() {
        assertThat(search("Unknown Surname")).isEmpty();
    }

    @Test
    @Transactional
    void ownersWithoutPetsRemainVisibleWithEmptyPetNames() {
        Owner owner = new Owner();
        owner.setFirstName("Contract");
        owner.setLastName("NoPet");
        owner.setAddress("1 Baseline Way");
        owner.setCity("Madison");
        owner.setTelephone("6085550000");
        this.clinicService.saveOwner(owner);

        assertThat(search("NoPet")).containsExactly(
            owner(owner.getId(), "Contract", "NoPet", "1 Baseline Way", "Madison", "6085550000")
        );
    }

    @Test
    void ownersWithMultiplePetsExposeStablePetNameOrdering() {
        assertThat(search("Coleman")).containsExactly(
            owner(6, "Jean", "Coleman", "105 N. Lake St.", "Monona", "6085552654", "Max", "Samantha")
        );
    }

    @Test
    void searchDoesNotReturnDuplicateOwners() {
        List<Integer> ownerIds = search("").stream()
            .map(OwnerSearchProjection::id)
            .toList();

        assertThat(ownerIds).doesNotHaveDuplicates();
    }

    private List<OwnerSearchProjection> search(String lastName) {
        Collection<Owner> owners = this.clinicService.findOwnerByLastName(lastName);
        return owners.stream()
            .map(OwnerSearchProjection::from)
            .toList();
    }

    private OwnerSearchProjection owner(
        int id,
        String firstName,
        String lastName,
        String address,
        String city,
        String telephone,
        String... petNames
    ) {
        return new OwnerSearchProjection(id, firstName, lastName, address, city, telephone, List.of(petNames));
    }

    private record OwnerSearchProjection(
        int id,
        String firstName,
        String lastName,
        String address,
        String city,
        String telephone,
        List<String> petNames
    ) {

        static OwnerSearchProjection from(Owner owner) {
            return new OwnerSearchProjection(
                owner.getId(),
                owner.getFirstName(),
                owner.getLastName(),
                owner.getAddress(),
                owner.getCity(),
                owner.getTelephone(),
                owner.getPets().stream().map(Pet::getName).toList()
            );
        }
    }
}
