package org.springframework.samples.petclinic.service;

import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.junit.jupiter.SpringJUnitConfig;

@SpringJUnitConfig(locations = {"classpath:spring/business-config.xml"})
@ActiveProfiles("jpa")
class JpaOwnerSearchContractTests extends AbstractOwnerSearchContractTests {

}
