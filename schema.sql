CREATE SCHEMA IF NOT EXISTS retail_store;

CREATE TABLE IF NOT EXISTS retail_store.customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100),
    email       VARCHAR(150),
    city        VARCHAR(100),
    signup_date DATE
);

CREATE TABLE IF NOT EXISTS retail_store.products (
    product_id SERIAL PRIMARY KEY,
    title      VARCHAR(200),
    category   VARCHAR(100),
    price      NUMERIC(10,2)
);

CREATE TABLE IF NOT EXISTS retail_store.orders (
    order_id    SERIAL PRIMARY KEY,
    customer_id INT REFERENCES retail_store.customers(customer_id),
    product_id  INT REFERENCES retail_store.products(product_id),
    quantity    INT,
    order_date  DATE,
    status      VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS retail_store.payments (
    payment_id   SERIAL PRIMARY KEY,
    order_id     INT REFERENCES retail_store.orders(order_id),
    payment_date DATE,
    amount       NUMERIC(10,2),
    method       VARCHAR(50)
);
