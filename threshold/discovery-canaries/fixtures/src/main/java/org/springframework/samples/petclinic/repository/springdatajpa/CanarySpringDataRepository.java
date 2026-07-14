package org.springframework.samples.petclinic.repository.springdatajpa;

import org.springframework.data.jpa.repository.Query;

interface CanarySpringDataRepository {

    @Query("SELECT owner FROM Owner owner WHERE owner.lastName LIKE :lastName AND owner.city IS NOT NULL ORDER BY owner.lastName, owner.firstName")
    String findCanaryOwner(String lastName);

}
