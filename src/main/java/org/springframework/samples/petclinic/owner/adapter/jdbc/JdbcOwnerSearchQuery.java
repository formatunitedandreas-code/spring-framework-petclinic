package org.springframework.samples.petclinic.owner.adapter.jdbc;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.springframework.jdbc.core.ResultSetExtractor;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.samples.petclinic.owner.api.OwnerListItem;
import org.springframework.samples.petclinic.owner.port.OwnerSearchQuery;
import org.springframework.stereotype.Repository;

@Repository
public class JdbcOwnerSearchQuery implements OwnerSearchQuery {

    private static final String OWNER_ID = "owner_id";

    private static final String SEARCH_BY_LAST_NAME_SQL = """
        SELECT owners.id AS owner_id,
               owners.first_name,
               owners.last_name,
               owners.address,
               owners.city,
               owners.telephone,
               pets.name AS pet_name
        FROM owners
        LEFT OUTER JOIN pets ON owners.id = pets.owner_id
        WHERE owners.last_name LIKE :lastName
        ORDER BY owners.id, LOWER(pets.name), pets.name
        """;

    private final JdbcClient jdbcClient;

    public JdbcOwnerSearchQuery(JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;
    }

    @Override
    public List<OwnerListItem> searchByLastName(String lastName) {
        return this.jdbcClient.sql(SEARCH_BY_LAST_NAME_SQL)
            .param("lastName", lastName + "%")
            .query((ResultSetExtractor<List<OwnerListItem>>) this::extractOwnerListItems);
    }

    private List<OwnerListItem> extractOwnerListItems(ResultSet rs) throws SQLException {
        Map<Integer, OwnerListItemBuilder> owners = new LinkedHashMap<>();
        while (rs.next()) {
            OwnerListItemBuilder owner = owners.computeIfAbsent(rs.getInt(OWNER_ID), ignored -> newOwner(rs));
            String petName = rs.getString("pet_name");
            if (petName != null) {
                owner.petNames().add(petName);
            }
        }
        return owners.values().stream().map(OwnerListItemBuilder::build).toList();
    }

    private OwnerListItemBuilder newOwner(ResultSet rs) {
        try {
            return new OwnerListItemBuilder(rs.getInt(OWNER_ID), rs.getString("first_name"),
                rs.getString("last_name"), rs.getString("address"), rs.getString("city"),
                rs.getString("telephone"), new ArrayList<>());
        }
        catch (SQLException ex) {
            throw new IllegalStateException("Unable to project owner search row", ex);
        }
    }

    private record OwnerListItemBuilder(int id, String firstName, String lastName, String address, String city,
            String telephone, List<String> petNames) {
        OwnerListItem build() {
            return new OwnerListItem(this.id, this.firstName, this.lastName, this.address, this.city, this.telephone,
                this.petNames);
        }
    }
}
