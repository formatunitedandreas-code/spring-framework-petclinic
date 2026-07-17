package org.springframework.samples.petclinic.owner.application;

import java.util.List;
import java.util.Objects;

import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;

public final class SearchOwners {

    private final OwnerSearchQuery ownerSearchQuery;

    public SearchOwners(OwnerSearchQuery ownerSearchQuery) {
        this.ownerSearchQuery = Objects.requireNonNull(ownerSearchQuery);
    }

    public List<OwnerListItem> searchByLastName(String lastName) {
        return List.copyOf(this.ownerSearchQuery.searchByLastName(normalizeLastName(lastName)));
    }

    private String normalizeLastName(String lastName) {
        if (lastName == null) {
            return "";
        }
        return lastName;
    }
}
