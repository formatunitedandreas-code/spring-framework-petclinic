package org.springframework.samples.petclinic.owner.api;

import java.util.List;

public record OwnerListItem(
    int id,
    String firstName,
    String lastName,
    String address,
    String city,
    String telephone,
    List<String> petNames
) {

    public OwnerListItem {
        petNames = List.copyOf(petNames);
    }
}
