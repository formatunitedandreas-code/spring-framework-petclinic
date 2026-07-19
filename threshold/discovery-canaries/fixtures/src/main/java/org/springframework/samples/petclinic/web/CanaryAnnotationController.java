package org.springframework.samples.petclinic.web;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;

class CanaryAnnotationController {

    @GetMapping(value = "/canary/annotation-format.json", produces = MediaType.APPLICATION_JSON_VALUE)
    String showCanary() {
        return "canary";
    }

}
