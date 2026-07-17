package org.springframework.samples.petclinic.service;

import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringJUnitConfig(locations = {
    "classpath:org/springframework/samples/petclinic/service/owner-search-query-counting-config.xml"
})
@ActiveProfiles("spring-data-jpa")
class SpringDataJpaOwnerSearchQueryMeasurementTests extends AbstractOwnerSearchQueryMeasurementTests {

    @Override
    protected int expectedSingleOwnerQueryCount() {
        return 2;
    }

    @Override
    protected int expectedAllOwnersQueryCount() {
        return 7;
    }

}
