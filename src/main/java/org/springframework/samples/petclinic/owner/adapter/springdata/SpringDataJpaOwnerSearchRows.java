package org.springframework.samples.petclinic.owner.adapter.springdata;

import java.util.List;

import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.Repository;
import org.springframework.data.repository.query.Param;
import org.springframework.samples.petclinic.model.Owner;

interface SpringDataJpaOwnerSearchRows extends Repository<Owner, Integer> {

    @Query("""
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
        """)
    List<OwnerSearchRow> search(@Param("lastName") String lastName);

    interface OwnerSearchRow {
        Integer getOwnerId();
        String getFirstName();
        String getLastName();
        String getAddress();
        String getCity();
        String getTelephone();
        String getPetName();
    }
}
