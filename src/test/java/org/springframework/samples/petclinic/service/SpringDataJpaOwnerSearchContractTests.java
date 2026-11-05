package org.springframework.samples.petclinic.service;

import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringJUnitConfig(locations = {"classpath:spring/business-config.xml"})
@ActiveProfiles("spring-data-jpa")
class SpringDataJpaOwnerSearchContractTests extends AbstractOwnerSearchContractTests {

}
