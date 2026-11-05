package org.springframework.samples.petclinic.owner.port;

import java.util.List;

import org.springframework.samples.petclinic.owner.api.OwnerListItem;

public interface OwnerSearchQuery {

    List<OwnerListItem> searchByLastName(String lastName);
}
