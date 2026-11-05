package org.springframework.samples.petclinic.service;

import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringJUnitConfig(locations = {
    "classpath:org/springframework/samples/petclinic/service/owner-search-query-counting-config.xml"
})
@ActiveProfiles("jdbc")
class JdbcOwnerSearchQueryMeasurementTests extends AbstractOwnerSearchQueryMeasurementTests {

    @Override
    protected int expectedSingleOwnerQueryCount() {
        return 3;
    }

    @Override
    protected int expectedAllOwnersQueryCount() {
        return 21;
    }

    @Override
    protected int expectedAllOwnersLoadedVisitCount() {
        return 4;
    }

}
