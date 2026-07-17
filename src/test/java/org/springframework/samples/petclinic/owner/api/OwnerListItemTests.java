package org.springframework.samples.petclinic.owner.api;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.ArrayList;
import java.util.List;

import org.junit.jupiter.api.Test;

class OwnerListItemTests {

    @Test
    void exposesOnlyOwnerSearchListFields() {
        OwnerListItem item = new OwnerListItem(
            1,
            "George",
            "Franklin",
            "110 W. Liberty St.",
            "Madison",
            "6085551023",
            List.of("Leo")
        );

        assertThat(item.id()).isEqualTo(1);
        assertThat(item.firstName()).isEqualTo("George");
        assertThat(item.lastName()).isEqualTo("Franklin");
        assertThat(item.address()).isEqualTo("110 W. Liberty St.");
        assertThat(item.city()).isEqualTo("Madison");
        assertThat(item.telephone()).isEqualTo("6085551023");
        assertThat(item.petNames()).containsExactly("Leo");
    }

    @Test
    void defensivelyCopiesPetNames() {
        List<String> petNames = new ArrayList<>();
        petNames.add("Basil");

        OwnerListItem item = new OwnerListItem(2, "Betty", "Davis", "638 Cardinal Ave.", "Sun Prairie",
            "6085551749", petNames);
        petNames.add("Zelda");

        assertThat(item.petNames()).containsExactly("Basil");
    }

    @Test
    void petNamesAreImmutableAndKeepInputOrdering() {
        OwnerListItem item = new OwnerListItem(6, "Jean", "Coleman", "105 N. Lake St.", "Monona",
            "6085552654", List.of("Max", "Samantha"));

        assertThat(item.petNames()).containsExactly("Max", "Samantha");
        assertThatThrownBy(() -> item.petNames().add("Lucky"))
            .isInstanceOf(UnsupportedOperationException.class);
    }

    @Test
    void valueEqualityIncludesPetNames() {
        OwnerListItem item = new OwnerListItem(1, "George", "Franklin", "110 W. Liberty St.", "Madison",
            "6085551023", List.of("Leo"));

        assertThat(item).isEqualTo(new OwnerListItem(1, "George", "Franklin", "110 W. Liberty St.", "Madison",
            "6085551023", List.of("Leo")));
        assertThat(item).isNotEqualTo(new OwnerListItem(1, "George", "Franklin", "110 W. Liberty St.", "Madison",
            "6085551023", List.of("Basil")));
    }
}
