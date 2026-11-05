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

    public int getId() {
        return id;
    }

    public String getFirstName() {
        return firstName;
    }

    public String getLastName() {
        return lastName;
    }

    public String getAddress() {
        return address;
    }

    public String getCity() {
        return city;
    }

    public String getTelephone() {
        return telephone;
    }

    public List<String> getPetNames() {
        return petNames;
    }
}
