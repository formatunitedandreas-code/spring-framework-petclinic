package org.springframework.samples.petclinic.repository.jdbc;

class CanaryJdbcRepository {

    private static final String LONG_CANARY_SQL = "SELECT owner.id, owner.first_name, owner.last_name, owner.address, owner.city, owner.telephone " +
        "FROM owners owner WHERE owner.last_name LIKE :lastName ORDER BY owner.last_name";

    String findCanaryOwner() {
        return this.jdbcClient.sql("SELECT owner.id, owner.first_name, owner.last_name FROM owners owner WHERE owner.last_name LIKE :lastName")
            .query(String.class)
            .single();
    }

}
