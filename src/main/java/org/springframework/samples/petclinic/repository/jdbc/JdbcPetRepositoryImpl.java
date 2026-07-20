/*
 * Copyright 2002-2022 the original author or authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in
 * writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.repository.jdbc;

import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.BeanPropertyRowMapper;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.core.simple.SimpleJdbcInsert;
import org.springframework.orm.ObjectRetrievalFailureException;
import org.springframework.samples.petclinic.model.Owner;
import org.springframework.samples.petclinic.model.Pet;
import org.springframework.samples.petclinic.model.PetType;
import org.springframework.samples.petclinic.repository.OwnerRepository;
import org.springframework.samples.petclinic.repository.PetRepository;
import org.springframework.samples.petclinic.util.EntityUtils;
import org.springframework.stereotype.Repository;

import javax.sql.DataSource;
import java.util.List;

/**
 * @author Ken Krebs
 * @author Juergen Hoeller
 * @author Rob Harrop
 * @author Sam Brannen
 * @author Thomas Risberg
 * @author Mark Fisher
 * @author Antoine Rey
 */
@Repository
public class JdbcPetRepositoryImpl implements PetRepository {

    private static final String ID = "id";

    private static final String NAME = "name";


    private static final String FIND_OWNER_ID_BY_PET_ID_SQL = "SELECT owner_id FROM pets WHERE "
        + "id=:id";

    private static final String FIND_PET_TYPES_SQL = "SELECT id, name FROM types ORDER BY " +
        NAME;

    private static final String SAVE_SQL = """
                    UPDATE pets
                    SET name=:name, birth_date=:birth_date, type_id=:type_id, owner_id=:owner_id
                    WHERE id=:id
                    """;

    private final JdbcClient jdbcClient;

    private final SimpleJdbcInsert insertPet;

    private final OwnerRepository ownerRepository;

    public JdbcPetRepositoryImpl(
        JdbcClient jdbcClient,
        DataSource dataSource,
        OwnerRepository ownerRepository
    ) {
        this.jdbcClient = jdbcClient;

        this.insertPet = new SimpleJdbcInsert(dataSource)
            .withTableName("pets")
            .usingGeneratedKeyColumns(ID);

        this.ownerRepository = ownerRepository;
    }

    @Override
    public List<PetType> findPetTypes() {
        return this.jdbcClient
            .sql(FIND_PET_TYPES_SQL)
            .query(BeanPropertyRowMapper.newInstance(PetType.class))
            .list();
    }

    @Override
    public Pet findById(int id) {
        try {
            return EntityUtils.getById(
                this.ownerRepository.findById(findOwnerIdByPetId(id)).getPets(),
                Pet.class,
                id
            );
        } catch (EmptyResultDataAccessException ex) {
            throw new ObjectRetrievalFailureException(Pet.class, id);
        }
    }

    private int findOwnerIdByPetId(int petId) {
        return this.jdbcClient
            .sql(FIND_OWNER_ID_BY_PET_ID_SQL)
            .param(ID, petId)
            .query(Integer.class)
            .single();
    }

    @Override
    public void save(Pet pet) {
        MapSqlParameterSource parameterSource = createPetParameterSource(pet);
        if (pet.isNew()) {
            pet.setId(this.insertPet.executeAndReturnKey(parameterSource).intValue());
            return;
        }
        this.jdbcClient
                .sql(SAVE_SQL)
                .paramSource(parameterSource)
                .update();
    }

    /**
     * Creates a {@link MapSqlParameterSource} based on data values
     * from the supplied
     * {@link Pet} instance.
     */
    private MapSqlParameterSource createPetParameterSource(Pet pet) {
        return new MapSqlParameterSource()
            .addValue(ID, pet.getId())
            .addValue(NAME, pet.getName())
            .addValue("birth_date", pet.getBirthDate())
            .addValue("type_id", pet.getType().getId())
            .addValue("owner_id", pet.getOwner().getId());
    }

}
