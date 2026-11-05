package org.springframework.samples.petclinic.service;

import java.util.concurrent.atomic.AtomicInteger;

final class SqlStatementCounter {

    private final AtomicInteger count = new AtomicInteger();

    void reset() {
        this.count.set(0);
    }

    void increment() {
        this.count.incrementAndGet();
    }

    int count() {
        return this.count.get();
    }
}
