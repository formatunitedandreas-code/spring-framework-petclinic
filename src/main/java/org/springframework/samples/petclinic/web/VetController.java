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
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.springframework.samples.petclinic.web;

import org.springframework.http.MediaType;
import org.springframework.samples.petclinic.model.Vet;
import org.springframework.samples.petclinic.model.Vets;
import org.springframework.samples.petclinic.service.ClinicService;
import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.ResponseBody;

import java.util.Collection;
import java.util.Map;

/**
 * @author Juergen Hoeller
 * @author Mark Fisher
 * @author Ken Krebs
 * @author Arjen Poutsma
 */
@Controller
public class VetController {

    private static final String MODEL_ATTRIBUTE_VETS = "vets";
    private static final String VIEWS_VET_LIST = "vets/vetList";
    private static final String VETS_PATH = "/vets";
    private static final String VETS_JSON_PATH = "/vets.json";
    private static final String VETS_XML_PATH = "/vets.xml";
    private final ClinicService clinicService;

    public VetController(ClinicService clinicService) {
        this.clinicService = clinicService;
    }

    @GetMapping(VETS_PATH)
    public String showVetList(Map<String, Object> model) {
        // Here we are returning an object of type
        // 'Vets' rather than a
        // collection of Vet objects
        // so it is simpler for Object-Xml mapping
        addVetsToModel(model);
        return VIEWS_VET_LIST;
    }

    private void addVetsToModel(Map<String, Object> model) {
        model.put(MODEL_ATTRIBUTE_VETS, getVets());
    }

    @GetMapping(
        value = VETS_JSON_PATH,
        produces = MediaType.APPLICATION_JSON_VALUE
    )
    @ResponseBody
    public Vets showJsonVetList() {
        return getVets();
    }

    @GetMapping(
        value = VETS_XML_PATH,
        produces = MediaType.APPLICATION_XML_VALUE
    )
    @ResponseBody
    public Vets showXmlVetList() {
        return getVets();
    }

    private Vets getVets() {
        // Here we are returning an object of type
        // 'Vets' rather than a
        // collection of Vet objects
        // so it is simpler for JSon/Object mapping
        return createVets(this.clinicService.findVets());
    }

    private Vets createVets(Collection<Vet> vets) {
        Vets mappedVets = new Vets();
        mappedVets.getVetList().addAll(vets);
        return mappedVets;
    }

}
