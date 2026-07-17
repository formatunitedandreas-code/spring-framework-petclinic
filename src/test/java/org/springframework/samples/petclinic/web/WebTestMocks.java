package org.springframework.samples.petclinic.web;

import org.springframework.samples.petclinic.owner.application.SearchOwners;

import static org.mockito.Mockito.mock;

public final class WebTestMocks {

    private WebTestMocks() {
    }

    public static SearchOwners searchOwners() {
        return mock(SearchOwners.class);
    }
}
