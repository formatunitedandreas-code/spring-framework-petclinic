package org.springframework.samples.petclinic.owner.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;

class SearchOwnersTests {

    @Test
    void normalizesNullLastNameToEmptyString() {
        RecordingOwnerSearchQuery query = new RecordingOwnerSearchQuery(List.of());

        new SearchOwners(query).searchByLastName(null);

        assertThat(query.lastName()).isEqualTo("");
    }

    @Test
    void preservesNonNullLastNameInput() {
        RecordingOwnerSearchQuery query = new RecordingOwnerSearchQuery(List.of());

        new SearchOwners(query).searchByLastName("Davis");

        assertThat(query.lastName()).isEqualTo("Davis");
    }

    @Test
    void returnsOwnerListItemsFromPortInOrder() {
        OwnerListItem betty = owner(2, "Betty", "Davis", "Basil");
        OwnerListItem harold = owner(4, "Harold", "Davis", "Iggy");
        SearchOwners searchOwners = new SearchOwners(new RecordingOwnerSearchQuery(List.of(betty, harold)));

        assertThat(searchOwners.searchByLastName("Davis")).containsExactly(betty, harold);
    }

    @Test
    void defensivelyCopiesPortResult() {
        OwnerListItem george = owner(1, "George", "Franklin", "Leo");
        List<OwnerListItem> result = new ArrayList<>();
        result.add(george);
        SearchOwners searchOwners = new SearchOwners(new RecordingOwnerSearchQuery(result));

        List<OwnerListItem> owners = searchOwners.searchByLastName("Franklin");
        result.clear();

        assertThat(owners).containsExactly(george);
        assertThatThrownBy(() -> owners.add(owner(2, "Betty", "Davis", "Basil")))
            .isInstanceOf(UnsupportedOperationException.class);
    }

    private OwnerListItem owner(int id, String firstName, String lastName, String petName) {
        return new OwnerListItem(id, firstName, lastName, "address", "city", "telephone", List.of(petName));
    }

    private static final class RecordingOwnerSearchQuery implements OwnerSearchQuery {

        private final List<OwnerListItem> result;

        private String lastName;

        private RecordingOwnerSearchQuery(List<OwnerListItem> result) {
            this.result = result;
        }

        @Override
        public List<OwnerListItem> searchByLastName(String lastName) {
            this.lastName = lastName;
            return this.result;
        }

        private String lastName() {
            return this.lastName;
        }
    }
}
