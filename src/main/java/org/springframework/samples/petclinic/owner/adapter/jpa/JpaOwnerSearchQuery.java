package org.springframework.samples.petclinic.owner.adapter.jpa;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Tuple;

import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;
import org.springframework.stereotype.Repository;

@Repository
public class JpaOwnerSearchQuery implements OwnerSearchQuery {

    private static final String LAST_NAME = "lastName";

    private static final String SEARCH_BY_LAST_NAME_JPQL = """
        SELECT owner.id AS ownerId,
               owner.firstName AS firstName,
               owner.lastName AS lastName,
               owner.address AS address,
               owner.city AS city,
               owner.telephone AS telephone,
               pet.name AS petName
        FROM Owner owner
        LEFT JOIN owner.pets pet
        WHERE owner.lastName LIKE :lastName
        ORDER BY owner.id, LOWER(pet.name), pet.name
        """;

    private final EntityManager entityManager;

    public JpaOwnerSearchQuery(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    @Override
    public List<OwnerListItem> searchByLastName(String lastName) {
        Map<Integer, OwnerListItemBuilder> owners = new LinkedHashMap<>();
        for (Tuple row : queryRows(lastName)) {
            OwnerListItemBuilder owner = owners.computeIfAbsent(row.get("ownerId", Integer.class),
                ignored -> newOwner(row));
            String petName = row.get("petName", String.class);
            if (petName != null) {
                owner.petNames().add(petName);
            }
        }
        return owners.values().stream().map(OwnerListItemBuilder::build).toList();
    }

    private List<Tuple> queryRows(String lastName) {
        return this.entityManager.createQuery(SEARCH_BY_LAST_NAME_JPQL, Tuple.class)
            .setParameter(LAST_NAME, lastName + "%")
            .getResultList();
    }

    private OwnerListItemBuilder newOwner(Tuple row) {
        return new OwnerListItemBuilder(row.get("ownerId", Integer.class), row.get("firstName", String.class),
            row.get(LAST_NAME, String.class), row.get("address", String.class), row.get("city", String.class),
            row.get("telephone", String.class), new ArrayList<>());
    }

    private record OwnerListItemBuilder(int id, String firstName, String lastName, String address, String city,
            String telephone, List<String> petNames) {
        OwnerListItem build() {
            return new OwnerListItem(this.id, this.firstName, this.lastName, this.address, this.city, this.telephone,
                this.petNames);
        }
    }
}
