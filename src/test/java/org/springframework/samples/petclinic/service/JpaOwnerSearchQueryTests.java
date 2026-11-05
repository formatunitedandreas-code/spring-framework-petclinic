package org.springframework.samples.petclinic.service;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringJUnitConfig(locations = {
    "classpath:org/springframework/samples/petclinic/service/owner-search-query-counting-config.xml"
})
@ActiveProfiles("jpa")
class JpaOwnerSearchQueryTests {

    @Autowired
    private OwnerSearchQuery ownerSearchQuery;

    @Autowired
    private SqlStatementCounter sqlStatementCounter;

    @Test
    void searchByExactPrefixReturnsProjectedOwnersInOneQuery() {
        List<OwnerListItem> owners = measure("Davis");

        assertThat(owners).containsExactly(
            owner(2, "Betty", "Davis", "638 Cardinal Ave.", "Sun Prairie", "6085551749", "Basil"),
            owner(4, "Harold", "Davis", "563 Friendly St.", "Windsor", "6085553198", "Iggy")
        );
        assertThat(this.sqlStatementCounter.count()).isEqualTo(1);
    }

    @Test
    void searchWithEmptyStringReturnsAllSeededOwnersWithoutDuplicatesOrVisitStateInOneQuery() {
        List<OwnerListItem> owners = measure("");

        assertThat(owners).hasSize(10);
        assertThat(owners).extracting(OwnerListItem::id).doesNotHaveDuplicates();
        assertThat(owners).extracting(OwnerListItem::id).containsExactly(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
        assertThat(owners).flatExtracting(OwnerListItem::petNames).hasSize(13);
        assertThat(OwnerListItem.class.getRecordComponents()).extracting(record -> record.getName())
            .doesNotContain("visits");
        assertThat(this.sqlStatementCounter.count()).isEqualTo(1);
    }

    @Test
    void ownersWithMultiplePetsExposeStablePetNameOrdering() {
        assertThat(measure("Coleman")).containsExactly(
            owner(6, "Jean", "Coleman", "105 N. Lake St.", "Monona", "6085552654", "Max", "Samantha")
        );
        assertThat(this.sqlStatementCounter.count()).isEqualTo(1);
    }

    private List<OwnerListItem> measure(String lastName) {
        this.sqlStatementCounter.reset();
        return this.ownerSearchQuery.searchByLastName(lastName);
    }

    private OwnerListItem owner(
        int id,
        String firstName,
        String lastName,
        String address,
        String city,
        String telephone,
        String... petNames
    ) {
        return new OwnerListItem(id, firstName, lastName, address, city, telephone, List.of(petNames));
    }
}
