CREATE SCHEMA IF NOT EXISTS retail_store;

CREATE TABLE retail_store.customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100),
    email       VARCHAR(150),
    city        VARCHAR(100),
    signup_date DATE
);

CREATE TABLE retail_store.products (
    product_id SERIAL PRIMARY KEY,
    title      VARCHAR(200),
    category   VARCHAR(100),
    price      NUMERIC(10,2)
);

CREATE TABLE retail_store.orders (
    order_id    SERIAL PRIMARY KEY,
    customer_id INT REFERENCES retail_store.customers(customer_id),
    product_id  INT REFERENCES retail_store.products(product_id),
    quantity    INT,
    order_date  DATE,
    status      VARCHAR(50)
);

CREATE TABLE retail_store.payments (
    payment_id   SERIAL PRIMARY KEY,
    order_id     INT REFERENCES retail_store.orders(order_id),
    payment_date DATE,
    amount       NUMERIC(10,2),
    method       VARCHAR(50)
);

SELECT 
    SUM(CASE WHEN full_name IS NULL THEN 1 ELSE 0 END) AS null_name,
    SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END) AS null_email,
    SUM(CASE WHEN city IS NULL THEN 1 ELSE 0 END) AS null_city,
    SUM(CASE WHEN signup_date IS NULL THEN 1 ELSE 0 END) AS null_signup
FROM retail_store.customers;

SELECT email, COUNT(*) 
FROM retail_store.customers
GROUP BY email
HAVING COUNT(*) > 1;

SELECT title, category, price, COUNT(*)
FROM retail_store.products
GROUP BY title, category, price
HAVING COUNT(*) > 1;

SELECT o.* FROM retail_store.orders o
LEFT JOIN retail_store.customers c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

SELECT o.* FROM retail_store.orders o
LEFT JOIN retail_store.products p ON o.product_id = p.product_id
WHERE p.product_id IS NULL;

SELECT pay.* FROM retail_store.payments pay
LEFT JOIN retail_store.orders o ON pay.order_id = o.order_id
WHERE o.order_id IS NULL;

SELECT * FROM retail_store.orders WHERE quantity <= 0;
SELECT * FROM retail_store.products WHERE price <= 0;
SELECT * FROM retail_store.payments WHERE amount <= 0;


-- Payments were made before the orders were even made
SELECT pay.payment_id, o.order_date, pay.payment_date
FROM retail_store.payments pay
JOIN retail_store.orders o ON pay.order_id = o.order_id
WHERE pay.payment_date < o.order_date;

-- Fix for the above query
SELECT 'customers' AS tbl, COUNT(*), MIN(customer_id), MAX(customer_id) FROM retail_store.customers
UNION ALL
SELECT 'products', COUNT(*), MIN(product_id), MAX(product_id) FROM retail_store.products
UNION ALL
SELECT 'orders', COUNT(*), MIN(order_id), MAX(order_id) FROM retail_store.orders
UNION ALL
SELECT 'payments', COUNT(*), MIN(payment_id), MAX(payment_id) FROM retail_store.payments;

SELECT order_id, order_id - ROW_NUMBER() OVER (ORDER BY order_id) AS gap_marker
FROM retail_store.orders
ORDER BY order_id;

SELECT * FROM retail_store.customers ORDER BY customer_id LIMIT 3;
SELECT * FROM retail_store.orders ORDER BY order_id LIMIT 3;
SELECT * FROM retail_store.payments ORDER BY payment_id LIMIT 3;

SELECT order_id, payment_date, amount, method, COUNT(*)
FROM retail_store.payments
GROUP BY order_id, payment_date, amount, method
HAVING COUNT(*) > 1;

SELECT full_name, email, city, signup_date, COUNT(*)
FROM retail_store.customers
GROUP BY full_name, email, city, signup_date
HAVING COUNT(*) > 1;

SELECT order_id, payment_date, amount, method, COUNT(*)
FROM retail_store.payments
GROUP BY order_id, payment_date, amount, method
HAVING COUNT(*) > 1;

SELECT customer_id, product_id, quantity, order_date, status, COUNT(*)
FROM retail_store.orders
GROUP BY customer_id, product_id, quantity, order_date, status
HAVING COUNT(*) > 1;

SELECT * FROM retail_store.customers
WHERE full_name IS NULL OR email IS NULL OR city IS NULL OR signup_date IS NULL;

SELECT * FROM retail_store.orders
WHERE customer_id IS NULL OR product_id IS NULL OR quantity IS NULL OR order_date IS NULL OR status IS NULL;

SELECT * FROM retail_store.payments
WHERE order_id IS NULL OR payment_date IS NULL OR amount IS NULL OR method IS NULL;

SELECT 
    COUNT(*) AS total_payments,
    SUM(CASE WHEN pay.payment_date < o.order_date THEN 1 ELSE 0 END) AS bad_date_payments,
    ROUND(100.0 * SUM(CASE WHEN pay.payment_date < o.order_date THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_bad
FROM retail_store.payments pay
JOIN retail_store.orders o ON pay.order_id = o.order_id;

SELECT pay.payment_id, o.order_date, pay.payment_date,
       (o.order_date - pay.payment_date) AS days_early
FROM retail_store.payments pay
JOIN retail_store.orders o ON pay.order_id = o.order_id
WHERE pay.payment_date < o.order_date
ORDER BY days_early DESC;

CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE staging.payments AS
SELECT 
    pay.*,
    CASE WHEN pay.payment_date < o.order_date THEN TRUE ELSE FALSE END AS is_date_invalid
FROM retail_store.payments pay
JOIN retail_store.orders o ON pay.order_id = o.order_id;

WITH flagged_payments AS (
    SELECT pay.*, 
           CASE WHEN pay.payment_date < o.order_date THEN TRUE ELSE FALSE END AS is_date_invalid
    FROM retail_store.payments pay
    JOIN retail_store.orders o ON pay.order_id = o.order_id
)
SELECT * FROM flagged_payments WHERE is_date_invalid = TRUE;

CREATE TABLE staging.customers AS
SELECT
    customer_id,
    TRIM(full_name) AS full_name,
    LOWER(TRIM(email)) AS email,
    INITCAP(TRIM(city)) AS city,
    signup_date
FROM retail_store.customers;

CREATE TABLE staging.products AS
SELECT
    product_id,
    TRIM(title) AS title,
    LOWER(TRIM(category)) AS category,
    price,
    CASE WHEN price <= 0 THEN TRUE ELSE FALSE END AS is_price_invalid
FROM retail_store.products;

CREATE TABLE staging.orders AS
SELECT
    order_id,
    customer_id,
    product_id,
    quantity,
    order_date,
    LOWER(TRIM(status)) AS status,
    CASE WHEN quantity <= 0 THEN TRUE ELSE FALSE END AS is_quantity_invalid
FROM retail_store.orders;

SELECT order_id, COUNT(*) 
FROM staging.payments
GROUP BY order_id
HAVING COUNT(*) > 1;

SELECT o.order_id, o.status
FROM staging.orders o
LEFT JOIN staging.payments p ON o.order_id = p.order_id

WHERE p.order_id IS NULL;

CREATE SCHEMA IF NOT EXISTS warehouse;

CREATE TABLE warehouse.dim_customers AS
SELECT customer_id, full_name, email, city, signup_date
FROM staging.customers;

ALTER TABLE warehouse.dim_customers ADD PRIMARY KEY (customer_id);

CREATE TABLE warehouse.dim_products AS
SELECT product_id, title, category, price
FROM staging.products;

ALTER TABLE warehouse.dim_products ADD PRIMARY KEY (product_id);

CREATE TABLE warehouse.fact_orders AS
SELECT 
    o.order_id,
    o.customer_id,
    o.product_id,
    o.quantity,
    o.order_date,
    o.status,
    p.payment_date,
    p.amount,
    p.method,
    (o.quantity * pr.price) AS revenue
FROM staging.orders o
LEFT JOIN staging.payments p ON o.order_id = p.order_id
LEFT JOIN staging.products pr ON o.product_id = pr.product_id;

SELECT 'dim_customers' AS tbl, COUNT(*) FROM warehouse.dim_customers
UNION ALL
SELECT 'dim_products', COUNT(*) FROM warehouse.dim_products
UNION ALL
SELECT 'fact_orders', COUNT(*) FROM warehouse.fact_orders;

SELECT * FROM warehouse.dim_customers LIMIT 10;

SELECT * FROM warehouse.dim_products LIMIT 10;

SELECT * FROM warehouse.fact_orders LIMIT 10;

SELECT status, COUNT(*) AS orders_without_payment
FROM warehouse.fact_orders
WHERE amount IS NULL
GROUP BY status;

ALTER TABLE warehouse.fact_orders
ADD COLUMN is_payment_missing BOOLEAN;

-- Mark orders where payment amount is missing but status is completed
UPDATE warehouse.fact_orders
SET is_payment_missing = (amount IS NULL AND status = 'completed');

-- Quick count of orders with/without missing payment
SELECT is_payment_missing, COUNT(*) 
FROM warehouse.fact_orders
GROUP BY is_payment_missing;

-- Total revenue and order count by product category
SELECT p.category, 
       SUM(f.revenue) AS total_revenue,
       COUNT(*) AS order_count
FROM warehouse.fact_orders f
JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY total_revenue DESC;

-- Top 5 customers by total revenue (ranked)
SELECT customer_id, full_name, total_spent, rank
FROM (
    SELECT c.customer_id, c.full_name,
           SUM(f.revenue) AS total_spent,
           RANK() OVER (ORDER BY SUM(f.revenue) DESC) AS rank
    FROM warehouse.fact_orders f
    JOIN warehouse.dim_customers c ON f.customer_id = c.customer_id
    GROUP BY c.customer_id, c.full_name
) ranked
WHERE rank <= 5;

-- Monthly orders and revenue time series
SELECT 
    DATE_TRUNC('month', order_date) AS order_month,
    COUNT(*) AS order_count,
    SUM(revenue) AS monthly_revenue
FROM warehouse.fact_orders
GROUP BY DATE_TRUNC('month', order_date)
ORDER BY order_month;

-- Product return rates (only products with >=3 orders)
SELECT p.title,
       COUNT(*) AS total_orders,
       SUM(CASE WHEN f.status = 'returned' THEN 1 ELSE 0 END) AS returned_orders,
       ROUND(100.0 * SUM(CASE WHEN f.status = 'returned' THEN 1 ELSE 0 END) / COUNT(*), 1) AS return_rate_pct
FROM warehouse.fact_orders f
JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.title
HAVING COUNT(*) >= 3
ORDER BY return_rate_pct DESC;

-- Monthly signup cohorts with revenue and average revenue per customer
SELECT 
    DATE_TRUNC('month', c.signup_date) AS signup_month,
    COUNT(DISTINCT c.customer_id) AS customers_in_cohort,
    COALESCE(SUM(f.revenue), 0) AS total_revenue,
    ROUND(COALESCE(SUM(f.revenue), 0) / COUNT(DISTINCT c.customer_id), 2) AS avg_revenue_per_customer
FROM warehouse.dim_customers c
LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY DATE_TRUNC('month', c.signup_date)
ORDER BY signup_month;