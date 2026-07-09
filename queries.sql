-- Create schemas
CREATE SCHEMA IF NOT EXISTS retail_store;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS warehouse;

-- Create staging tables for validation
CREATE TABLE staging.customers_raw AS
SELECT *
FROM retail_store.customers;
CREATE TABLE staging.products_raw AS
SELECT *
FROM retail_store.products;
CREATE TABLE staging.orders_raw AS
SELECT *
FROM retail_store.orders;
CREATE TABLE staging.payments_raw AS
SELECT *
FROM retail_store.payments;

-- Check for null values
SELECT *
FROM staging.customers_raw
WHERE full_name IS NULL
    OR email IS NULL
    OR city IS NULL
    OR signup_date IS NULL;

SELECT *
FROM staging.orders_raw
WHERE customer_id IS NULL
    OR product_id IS NULL
    OR quantity IS NULL
    OR order_date IS NULL
    OR status IS NULL;

SELECT *
FROM staging.payments_raw
WHERE order_id IS NULL
    OR payment_date IS NULL
    OR amount IS NULL
    OR method IS NULL;

-- Check for duplicate values
SELECT email,
    COUNT(*)
FROM staging.customers_raw
GROUP BY email
HAVING COUNT(*) > 1;
SELECT title,
    category,
    price,
    COUNT(*)
FROM staging.products_raw
GROUP BY title,
    category,
    price
HAVING COUNT(*) > 1;
SELECT customer_id,
    product_id,
    quantity,
    order_date,
    status,
    COUNT(*)
FROM staging.orders_raw
GROUP BY customer_id,
    product_id,
    quantity,
    order_date,
    status
HAVING COUNT(*) > 1;
SELECT order_id,
    payment_date,
    amount,
    method,
    COUNT(*)
FROM staging.payments_raw
GROUP BY order_id,
    payment_date,
    amount,
    method
HAVING COUNT(*) > 1;

-- Check for invalid values
SELECT *
FROM staging.orders_raw
WHERE quantity <= 0;
SELECT *
FROM staging.products_raw
WHERE price <= 0;
SELECT *
FROM staging.payments_raw
WHERE amount <= 0;

-- Check for orphaned foreign keys
SELECT o.*
FROM staging.orders_raw o
    LEFT JOIN staging.customers_raw c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;
SELECT o.*
FROM staging.orders_raw o
    LEFT JOIN staging.products_raw p ON o.product_id = p.product_id
WHERE p.product_id IS NULL;
SELECT pay.*
FROM staging.payments_raw pay
    LEFT JOIN staging.orders_raw o ON pay.order_id = o.order_id
WHERE o.order_id IS NULL;

-- Check if the payment was made before the orders were placed (happened because our datasets did not contain natural primary keys)
SELECT pay.payment_id,
    o.order_date,
    pay.payment_date
FROM staging.payments_raw pay
    JOIN staging.orders_raw o ON pay.order_id = o.order_id
WHERE pay.payment_date < o.order_date;

-- Check for invalid dates 
SELECT *
FROM staging.orders_raw
WHERE order_date > CURRENT_DATE;
SELECT *
FROM staging.payments_raw
WHERE payment_date > CURRENT_DATE;
SELECT *
FROM staging.customers_raw
WHERE signup_date > CURRENT_DATE;

-- Creating staging tables with cleaned content
CREATE TABLE staging.customers_clean AS
SELECT customer_id,
    TRIM(full_name) AS full_name,
    LOWER(TRIM(email)) AS email,
    INITCAP(TRIM(city)) AS city,
    signup_date
FROM staging.customers_raw;
CREATE TABLE staging.products_clean AS
SELECT product_id,
    TRIM(title) AS title,
    LOWER(TRIM(category)) AS category,
    price
FROM staging.products_raw
WHERE price > 0;
CREATE TABLE staging.orders_clean AS
SELECT order_id,
    customer_id,
    product_id,
    quantity,
    order_date,
    LOWER(TRIM(status)) AS status
FROM staging.orders_raw
WHERE quantity > 0;
CREATE TABLE staging.payments_clean AS
SELECT payment_id,
    order_id,
    payment_date,
    amount,
    LOWER(TRIM(method)) AS method
FROM staging.payments_raw
WHERE amount > 0;

-- Creating the dimension tables for warehouse
CREATE TABLE warehouse.dim_customers AS
SELECT *
FROM staging.customers_clean;
ALTER TABLE warehouse.dim_customers
ADD PRIMARY KEY(customer_id);
CREATE TABLE warehouse.dim_products AS
SELECT *
FROM staging.products_clean;
ALTER TABLE warehouse.dim_products
ADD PRIMARY KEY(product_id);
CREATE TABLE warehouse.fact_orders AS
SELECT o.order_id,
    o.customer_id,
    o.product_id,
    o.quantity,
    o.order_date,
    o.status,
    p.payment_date,
    p.amount,
    p.method,
    (o.quantity * pr.price) AS revenue
FROM staging.orders_clean o
    LEFT JOIN staging.payments_clean p ON o.order_id = p.order_id
    LEFT JOIN staging.products_clean pr ON o.product_id = pr.product_id;

-- Check if all the rows are properly loaed
SELECT 'dim_customers',
    COUNT(*)
FROM warehouse.dim_customers
UNION ALL
SELECT 'dim_products',
    COUNT(*)
FROM warehouse.dim_products
UNION ALL
SELECT 'fact_orders',
    COUNT(*)
FROM warehouse.fact_orders;

-- Add a attribute to flag orders where payment information is not present
ALTER TABLE warehouse.fact_orders
ADD COLUMN is_payment_missing BOOLEAN;
UPDATE warehouse.fact_orders
SET is_payment_missing = (
        amount IS NULL
        AND status = 'completed'
    );

-- Check for the count of missing values
SELECT is_payment_missing,
    COUNT(*)
FROM warehouse.fact_orders
GROUP BY is_payment_missing;

-- Calculate the total revenue generated through the orders
SELECT p.category,
    SUM(f.revenue) AS total_revenue,
    COUNT(*) AS total_orders
FROM warehouse.fact_orders f
    JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY total_revenue DESC;

-- Window function to fetch the record of top 5 customers
SELECT customer_id,
    full_name,
    total_spent,
    customer_rank
FROM (
        SELECT c.customer_id,
            c.full_name,
            SUM(f.revenue) AS total_spent,
            RANK() OVER (
                ORDER BY SUM(f.revenue) DESC
            ) AS customer_rank
        FROM warehouse.fact_orders f
            JOIN warehouse.dim_customers c ON f.customer_id = c.customer_id
        GROUP BY c.customer_id,
            c.full_name
    ) ranked
WHERE customer_rank <= 5;

-- Calculate the number of orders and the revenue in all the months
SELECT DATE_TRUNC('month', order_date) AS order_month,
    COUNT(*) AS total_orders,
    SUM(revenue) AS total_revenue
FROM warehouse.fact_orders
GROUP BY DATE_TRUNC('month', order_date)
ORDER BY order_month;

-- Aggregate function to calculate the return rate of different products
SELECT p.title,
    COUNT(*) AS total_orders,
    SUM (
        CASE
            WHEN f.status = 'returned' THEN 1
            ELSE 0
        END
    ) AS returned_orders,
    ROUND (
        100.0 * SUM (
            CASE
                WHEN f.status = 'returned' THEN 1
                ELSE 0
            END
        ) / COUNT(*),
        2
    ) AS return_rate_percent
FROM warehouse.fact_orders f
    JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.title
HAVING COUNT(*) >= 3
ORDER BY return_rate_percent DESC;

-- Return the customers along with the number of orders placed within a motn
SELECT DATE_TRUNC ('month', c.signup_date) AS signup_month,
    COUNT (DISTINCT c.customer_id) AS customers,
    COALESCE (SUM(f.revenue), 0) AS total_revenue,
    ROUND (
        COALESCE ( -- COALESCE returns the first non-null values
            SUM(f.revenue),
            0
        ) / COUNT(DISTINCT c.customer_id),
        2
    ) AS avg_revenue_per_customer
FROM warehouse.dim_customers c
    LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY DATE_TRUNC ('month', c.signup_date)
ORDER BY signup_month;

-- Tells us the number of transactions and the amount spent according to the payment method
SELECT method,
    COUNT(*) AS total_transactions,
    SUM(amount) AS total_amount
FROM warehouse.fact_orders
GROUP BY method
ORDER BY total_transactions DESC;

-- Generates a stastical overview for the revenue 
SELECT ROUND(AVG(revenue), 2) AS average_order_value,
    MIN(revenue) AS minimum_order,
    MAX(revenue) AS maximum_order
FROM warehouse.fact_orders;

-- Tells about the top 10 selling products
SELECT p.title,
    SUM(f.quantity) AS total_quantity,
    SUM(f.revenue) AS total_revenue
FROM warehouse.fact_orders f
    JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.title
ORDER BY total_quantity DESC
LIMIT 10;

-- Tells us the spending habits of customers
SELECT c.customer_id,
    c.full_name,
    COUNT(f.order_id) AS total_orders,
    SUM(f.revenue) AS total_spent
FROM warehouse.dim_customers c
    LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY c.customer_id,
    c.full_name
ORDER BY total_orders DESC;

-- Checks for the orders where the order is completed but there is no information of the table
SELECT order_id,
    customer_id,
    status,
    amount
FROM warehouse.fact_orders
WHERE status = 'completed'
    AND amount IS NULL;