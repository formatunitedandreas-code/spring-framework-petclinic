package org.springframework.samples.petclinic.web;

import java.util.Collection;
import java.util.List;

import org.assertj.core.util.Lists;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.samples.petclinic.model.Owner;
import org.springframework.samples.petclinic.model.Pet;
import org.springframework.samples.petclinic.service.ClinicService;
import org.springframework.test.context.junit.jupiter.web.SpringJUnitWebConfig;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.hasProperty;
import static org.hamcrest.Matchers.is;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * Test class for {@link OwnerController}
 *
 * @author Colin But
 */

@SpringJUnitWebConfig(locations = {"classpath:spring/mvc-test-config.xml", "classpath:spring/mvc-core-config.xml"})
class OwnerControllerTests {

    private static final int TEST_OWNER_ID = 1;

    @Autowired
    private OwnerController ownerController;

    @Autowired
    private ClinicService clinicService;

    private MockMvc mockMvc;

    private Owner george;

    @BeforeEach
    void setup() {
        this.mockMvc = MockMvcBuilders.standaloneSetup(ownerController).build();

        george = new Owner();
        george.setId(TEST_OWNER_ID);
        george.setFirstName("George");
        george.setLastName("Franklin");
        george.setAddress("110 W. Liberty St.");
        george.setCity("Madison");
        george.setTelephone("6085551023");
        given(this.clinicService.findOwnerById(TEST_OWNER_ID)).willReturn(george);

    }

    @Test
    void testInitCreationForm() throws Exception {
        mockMvc.perform(get("/owners/new"))
            .andExpect(status().isOk())
            .andExpect(model().attributeExists("owner"))
            .andExpect(view().name("owners/createOrUpdateOwnerForm"));
    }

    @Test
    void testProcessCreationFormSuccess() throws Exception {
        mockMvc.perform(post("/owners/new")
            .param("firstName", "Joe")
            .param("lastName", "Bloggs")
            .param("address", "123 Caramel Street")
            .param("city", "London")
            .param("telephone", "01316761638")
        )
            .andExpect(status().is3xxRedirection());
    }

    @Test
    void testProcessCreationFormHasErrors() throws Exception {
        mockMvc.perform(post("/owners/new")
            .param("firstName", "Joe")
            .param("lastName", "Bloggs")
            .param("city", "London")
        )
            .andExpect(status().isOk())
            .andExpect(model().attributeHasErrors("owner"))
            .andExpect(model().attributeHasFieldErrors("owner", "address"))
            .andExpect(model().attributeHasFieldErrors("owner", "telephone"))
            .andExpect(view().name("owners/createOrUpdateOwnerForm"));
    }

    @Test
    void testInitFindForm() throws Exception {
        mockMvc.perform(get("/owners/find"))
            .andExpect(status().isOk())
            .andExpect(model().attributeExists("owner"))
            .andExpect(view().name("owners/findOwners"));
    }

    @Test
    void testProcessFindFormSuccess() throws Exception {
        given(this.clinicService.findOwnerByLastName("")).willReturn(Lists.newArrayList(george, new Owner()));

        mockMvc.perform(get("/owners"))
            .andExpect(status().isOk())
            .andExpect(view().name("owners/ownersList"));
    }

    @Test
    void parameterlessFindReturnsOwnersListForEmptyLastName() throws Exception {
        Owner betty = owner(2, "Betty", "Davis", "10 Ocean Ave.", "Madison", "6085551024");
        given(this.clinicService.findOwnerByLastName("")).willReturn(List.of(george, betty));

        MvcResult result = mockMvc.perform(get("/owners"))
            .andExpect(status().isOk())
            .andExpect(model().attributeExists("selections"))
            .andExpect(view().name("owners/ownersList"))
            .andReturn();

        assertThat(ownerSelections(result)).containsExactly(george, betty);
        verify(this.clinicService).findOwnerByLastName("");
    }

    @Test
    void multipleResultsPreserveOrderingOwnerFieldsAndPetNames() throws Exception {
        george.addPet(pet("Zelda"));
        george.addPet(pet("Basil"));
        Owner betty = owner(2, "Betty", "Franklin", "10 Ocean Ave.", "Madison", "6085551024");
        betty.addPet(pet("Rex"));
        given(this.clinicService.findOwnerByLastName("Franklin")).willReturn(List.of(george, betty));

        MvcResult result = mockMvc.perform(get("/owners").param("lastName", "Franklin"))
            .andExpect(status().isOk())
            .andExpect(view().name("owners/ownersList"))
            .andReturn();

        List<Owner> selections = ownerSelections(result);
        assertThat(selections).containsExactly(george, betty);
        assertThat(selections.get(0).getId()).isEqualTo(TEST_OWNER_ID);
        assertThat(selections.get(0).getFirstName()).isEqualTo("George");
        assertThat(selections.get(0).getLastName()).isEqualTo("Franklin");
        assertThat(selections.get(0).getAddress()).isEqualTo("110 W. Liberty St.");
        assertThat(selections.get(0).getCity()).isEqualTo("Madison");
        assertThat(selections.get(0).getTelephone()).isEqualTo("6085551023");
        assertThat(selections.get(0).getPets()).extracting(Pet::getName).containsExactly("Basil", "Zelda");
        assertThat(selections.get(1).getPets()).extracting(Pet::getName).containsExactly("Rex");
    }

    @Test
    void testProcessFindFormByLastName() throws Exception {
        given(this.clinicService.findOwnerByLastName(george.getLastName())).willReturn(Lists.newArrayList(george));

        mockMvc.perform(get("/owners")
            .param("lastName", "Franklin")
        )
            .andExpect(status().is3xxRedirection())
            .andExpect(view().name("redirect:/owners/" + TEST_OWNER_ID));
    }

    @Test
    void testProcessFindFormNoOwnersFound() throws Exception {
        given(this.clinicService.findOwnerByLastName("Unknown Surname")).willReturn(List.of());

        mockMvc.perform(get("/owners")
            .param("lastName", "Unknown Surname")
        )
            .andExpect(status().isOk())
            .andExpect(model().attributeHasFieldErrors("owner", "lastName"))
            .andExpect(model().attributeHasFieldErrorCode("owner", "lastName", "notFound"))
            .andExpect(view().name("owners/findOwners"));
    }

    @Test
    void oneResultRedirectsToOwnerDetailsPath() throws Exception {
        given(this.clinicService.findOwnerByLastName("Franklin")).willReturn(List.of(george));

        mockMvc.perform(get("/owners").param("lastName", "Franklin"))
            .andExpect(status().is3xxRedirection())
            .andExpect(view().name("redirect:/owners/" + TEST_OWNER_ID))
            .andExpect(redirectedUrl("/owners/" + TEST_OWNER_ID));
    }

    @Test
    void testInitUpdateOwnerForm() throws Exception {
        mockMvc.perform(get("/owners/{ownerId}/edit", TEST_OWNER_ID))
            .andExpect(status().isOk())
            .andExpect(model().attributeExists("owner"))
            .andExpect(model().attribute("owner", hasProperty("lastName", is("Franklin"))))
            .andExpect(model().attribute("owner", hasProperty("firstName", is("George"))))
            .andExpect(model().attribute("owner", hasProperty("address", is("110 W. Liberty St."))))
            .andExpect(model().attribute("owner", hasProperty("city", is("Madison"))))
            .andExpect(model().attribute("owner", hasProperty("telephone", is("6085551023"))))
            .andExpect(view().name("owners/createOrUpdateOwnerForm"));
    }

    @Test
    void testProcessUpdateOwnerFormSuccess() throws Exception {
        mockMvc.perform(post("/owners/{ownerId}/edit", TEST_OWNER_ID)
            .param("firstName", "Joe")
            .param("lastName", "Bloggs")
            .param("address", "123 Caramel Street")
            .param("city", "London")
            .param("telephone", "01616291589")
        )
            .andExpect(status().is3xxRedirection())
            .andExpect(view().name("redirect:/owners/{ownerId}"));
    }

    @Test
    void testProcessUpdateOwnerFormHasErrors() throws Exception {
        mockMvc.perform(post("/owners/{ownerId}/edit", TEST_OWNER_ID)
            .param("firstName", "Joe")
            .param("lastName", "Bloggs")
            .param("city", "London")
        )
            .andExpect(status().isOk())
            .andExpect(model().attributeHasErrors("owner"))
            .andExpect(model().attributeHasFieldErrors("owner", "address"))
            .andExpect(model().attributeHasFieldErrors("owner", "telephone"))
            .andExpect(view().name("owners/createOrUpdateOwnerForm"));
    }

    @Test
    void testShowOwner() throws Exception {
        mockMvc.perform(get("/owners/{ownerId}", TEST_OWNER_ID))
            .andExpect(status().isOk())
            .andExpect(model().attribute("owner", hasProperty("lastName", is("Franklin"))))
            .andExpect(model().attribute("owner", hasProperty("firstName", is("George"))))
            .andExpect(model().attribute("owner", hasProperty("address", is("110 W. Liberty St."))))
            .andExpect(model().attribute("owner", hasProperty("city", is("Madison"))))
            .andExpect(model().attribute("owner", hasProperty("telephone", is("6085551023"))))
            .andExpect(view().name("owners/ownerDetails"));
    }

    @SuppressWarnings("unchecked")
    private List<Owner> ownerSelections(MvcResult result) {
        MockHttpServletRequest request = result.getRequest();
        Object selections = request.getAttribute("selections");
        assertThat(selections).isInstanceOf(Collection.class);
        return List.copyOf((Collection<Owner>) selections);
    }

    private Owner owner(int id, String firstName, String lastName, String address, String city, String telephone) {
        Owner owner = new Owner();
        owner.setId(id);
        owner.setFirstName(firstName);
        owner.setLastName(lastName);
        owner.setAddress(address);
        owner.setCity(city);
        owner.setTelephone(telephone);
        return owner;
    }

    private Pet pet(String name) {
        Pet pet = new Pet();
        pet.setName(name);
        return pet;
    }

}
