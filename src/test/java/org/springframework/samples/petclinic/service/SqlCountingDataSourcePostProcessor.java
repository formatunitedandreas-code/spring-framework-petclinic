package org.springframework.samples.petclinic.service;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.Statement;

import javax.sql.DataSource;

import org.springframework.beans.BeansException;
import org.springframework.beans.factory.config.BeanPostProcessor;

public final class SqlCountingDataSourcePostProcessor implements BeanPostProcessor {

    private final SqlStatementCounter counter;

    public SqlCountingDataSourcePostProcessor(SqlStatementCounter counter) {
        this.counter = counter;
    }

    @Override
    public Object postProcessAfterInitialization(Object bean, String beanName) throws BeansException {
        if (!"dataSource".equals(beanName) || !(bean instanceof DataSource dataSource)) {
            return bean;
        }
        return Proxy.newProxyInstance(
            dataSource.getClass().getClassLoader(),
            new Class<?>[] {DataSource.class},
            new CountingDataSourceInvocationHandler(dataSource, this.counter)
        );
    }

    private static final class CountingDataSourceInvocationHandler implements InvocationHandler {

        private final DataSource delegate;

        private final SqlStatementCounter counter;

        private CountingDataSourceInvocationHandler(DataSource delegate, SqlStatementCounter counter) {
            this.delegate = delegate;
            this.counter = counter;
        }

        @Override
        public Object invoke(Object proxy, java.lang.reflect.Method method, Object[] args) throws Throwable {
            Object result = method.invoke(this.delegate, args);
            if (result instanceof Connection connection) {
                return countingConnection(connection, this.counter);
            }
            return result;
        }
    }

    private static Connection countingConnection(Connection connection, SqlStatementCounter counter) {
        return (Connection) Proxy.newProxyInstance(
            connection.getClass().getClassLoader(),
            new Class<?>[] {Connection.class},
            (proxy, method, args) -> {
                Object result = method.invoke(connection, args);
                if (result instanceof Statement && isStatementCreation(method.getName())) {
                    counter.increment();
                }
                return result;
            }
        );
    }

    private static boolean isStatementCreation(String methodName) {
        return "createStatement".equals(methodName)
            || "prepareStatement".equals(methodName)
            || "prepareCall".equals(methodName);
    }
}
