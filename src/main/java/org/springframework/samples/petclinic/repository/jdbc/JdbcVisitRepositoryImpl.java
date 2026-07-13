/*
 * Copyright 2002-2022 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.repository.jdbc;

import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.core.simple.SimpleJdbcInsert;
import org.springframework.samples.petclinic.model.Visit;
import org.springframework.samples.petclinic.repository.VisitRepository;
import org.springframework.stereotype.Repository;

import javax.sql.DataSource;
import java.util.List;

/**
 * A simple JDBC-based implementation of the {@link VisitRepository} interface.
 *
 * @author Ken Krebs
 * @author Juergen Hoeller
 * @author Rob Harrop
 * @author Sam Brannen
 * @author Thomas Risberg
 * @author Mark Fisher
 * @author Michael Isvy
 */
@Repository
public class JdbcVisitRepositoryImpl implements VisitRepository {

    private static final String ID = "id";

    private final JdbcClient jdbcClient;

    private final SimpleJdbcInsert insertVisit;

    public JdbcVisitRepositoryImpl(DataSource dataSource, JdbcClient jdbcClient) {
        this.jdbcClient = jdbcClient;

        this.insertVisit = new SimpleJdbcInsert(dataSource)
            .withTableName("visits")
            .usingGeneratedKeyColumns(ID);
    }


    @Override
    public void save(Visit visit) {
        if (!visit.isNew()) {
            throw new UnsupportedOperationException("Visit update not supported");
        }
        visit.setId(this.insertVisit.executeAndReturnKey(
            createVisitParameterSource(visit)).intValue());
    }


    /**
     * Creates a {@link MapSqlParameterSource} based on data values from the supplied {@link Visit} instance.
     */
    private MapSqlParameterSource createVisitParameterSource(Visit visit) {
        return new MapSqlParameterSource()
            .addValue(ID, visit.getId())
            .addValue("visit_date", visit.getDate())
            .addValue("description", visit.getDescription())
            .addValue("pet_id", visit.getPet().getId());
    }

    @Override
    public List<Visit> findByPetId(Integer petId) {
        JdbcPet pet = findPetById(petId);
        List<Visit> visits = findVisitsByPetId(petId);

        attachPetToVisits(visits, pet);

        return visits;
    }

    private JdbcPet findPetById(Integer petId) {
        return this.jdbcClient
            .sql("SELECT id, name, birth_date, type_id, owner_id FROM pets WHERE id=:id")
            .param(ID, petId)
            .query(new JdbcPetRowMapper())
            .single();
    }

    private List<Visit> findVisitsByPetId(Integer petId) {
        return this.jdbcClient
            .sql("SELECT id as visit_id, visit_date, description FROM visits WHERE pet_id=:id")
            .param(ID, petId)
            .query(new JdbcVisitRowMapper())
            .list();
    }

    private void attachPetToVisits(List<Visit> visits, JdbcPet pet) {
        for (Visit visit : visits) {
            attachPetToVisit(visit, pet);
        }
    }

    private void attachPetToVisit(Visit visit, JdbcPet pet) {
        visit.setPet(pet);
    }

}
