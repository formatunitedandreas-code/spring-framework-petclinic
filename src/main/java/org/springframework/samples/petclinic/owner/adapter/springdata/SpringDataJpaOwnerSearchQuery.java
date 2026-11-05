package org.springframework.samples.petclinic.owner.adapter.springdata;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;
import org.springframework.stereotype.Component;

@Component
public class SpringDataJpaOwnerSearchQuery implements OwnerSearchQuery {

    private final SpringDataJpaOwnerSearchRows ownerSearchRows;

    public SpringDataJpaOwnerSearchQuery(SpringDataJpaOwnerSearchRows ownerSearchRows) {
        this.ownerSearchRows = ownerSearchRows;
    }

    @Override
    public List<OwnerListItem> searchByLastName(String lastName) {
        Map<Integer, OwnerListItemBuilder> owners = new LinkedHashMap<>();
        for (SpringDataJpaOwnerSearchRows.OwnerSearchRow row : this.ownerSearchRows.search(lastName + "%")) {
            OwnerListItemBuilder owner = owners.computeIfAbsent(row.getOwnerId(), ignored -> newOwner(row));
            if (row.getPetName() != null) {
                owner.petNames().add(row.getPetName());
            }
        }
        return owners.values().stream().map(OwnerListItemBuilder::build).toList();
    }

    private OwnerListItemBuilder newOwner(SpringDataJpaOwnerSearchRows.OwnerSearchRow row) {
        return new OwnerListItemBuilder(row.getOwnerId(), row.getFirstName(), row.getLastName(), row.getAddress(),
            row.getCity(), row.getTelephone(), new ArrayList<>());
    }

    private record OwnerListItemBuilder(int id, String firstName, String lastName, String address, String city,
            String telephone, List<String> petNames) {
        OwnerListItem build() {
            return new OwnerListItem(this.id, this.firstName, this.lastName, this.address, this.city, this.telephone,
                this.petNames);
        }
    }
}
