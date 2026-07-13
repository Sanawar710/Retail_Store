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

--Null checks on required fields 
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

-- Duplicate customer emails
SELECT email, COUNT(*)
FROM staging.customers_raw
GROUP BY email
HAVING COUNT(*) > 1;

-- Duplicate products (same title/category/price)
SELECT title, category, price, COUNT(*)
FROM staging.products_raw
GROUP BY title, category, price
HAVING COUNT(*) > 1;

-- Duplicate orders (identical order rows)
SELECT customer_id, product_id, quantity, order_date, status, COUNT(*)
FROM staging.orders_raw
GROUP BY customer_id, product_id, quantity, order_date, status
HAVING COUNT(*) > 1;

-- Duplicate payments
SELECT order_id, payment_date, amount, method, COUNT(*)
FROM staging.payments_raw
GROUP BY order_id, payment_date, amount, method
HAVING COUNT(*) > 1;

-- Check invalid orders
SELECT *
FROM staging.orders_raw
WHERE quantity <= 0;

SELECT *
FROM staging.products_raw
WHERE price <= 0;

SELECT *
FROM staging.payments_raw
WHERE amount <= 0;

-- Orders referencing a customer that doesn't exist
SELECT o.*
FROM staging.orders_raw o
LEFT JOIN staging.customers_raw c ON o.customer_id = c.customer_id
WHERE c.customer_id IS NULL;

-- Orders referencing a product that doesn't exist
SELECT o.*
FROM staging.orders_raw o
LEFT JOIN staging.products_raw p ON o.product_id = p.product_id
WHERE p.product_id IS NULL;

-- Payments referencing an order that doesn't exist
SELECT pay.*
FROM staging.payments_raw pay
LEFT JOIN staging.orders_raw o ON pay.order_id = o.order_id
WHERE o.order_id IS NULL;

-- Flags payments dated before their order was placed. Possible because
-- these datasets don't enforce natural primary keys / referential timing.
SELECT pay.payment_id, o.order_date, pay.payment_date
FROM staging.payments_raw pay
JOIN staging.orders_raw o ON pay.order_id = o.order_id
WHERE pay.payment_date < o.order_date;

-- Check if the order and payment dates are valid
SELECT *
FROM staging.orders_raw
WHERE order_date > CURRENT_DATE;

SELECT *
FROM staging.payments_raw
WHERE payment_date > CURRENT_DATE;

SELECT *
FROM staging.customers_raw
WHERE signup_date > CURRENT_DATE;


-- Data Cleaning
CREATE TABLE staging.customers_clean AS
SELECT
    customer_id,
    TRIM(full_name)         AS full_name,
    LOWER(TRIM(email))      AS email,
    INITCAP(TRIM(city))     AS city,
    signup_date
FROM staging.customers_raw;

CREATE TABLE staging.products_clean AS
SELECT
    product_id,
    TRIM(title)             AS title,
    LOWER(TRIM(category))   AS category,
    price
FROM staging.products_raw
WHERE price > 0;

CREATE TABLE staging.orders_clean AS
SELECT
    order_id,
    customer_id,
    product_id,
    quantity,
    order_date,
    LOWER(TRIM(status))     AS status
FROM staging.orders_raw
WHERE quantity > 0;

CREATE TABLE staging.payments_clean AS
SELECT
    payment_id,
    order_id,
    payment_date,
    amount,
    LOWER(TRIM(method))     AS method
FROM staging.payments_raw
WHERE amount > 0;


-- Create Dimension Tables
CREATE TABLE warehouse.dim_customers AS
SELECT *
FROM staging.customers_clean;

ALTER TABLE warehouse.dim_customers
ADD PRIMARY KEY (customer_id);

CREATE TABLE warehouse.dim_products AS
SELECT *
FROM staging.products_clean;

ALTER TABLE warehouse.dim_products
ADD PRIMARY KEY (product_id);

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
FROM staging.orders_clean o
LEFT JOIN staging.payments_clean p  ON o.order_id   = p.order_id
LEFT JOIN staging.products_clean pr ON o.product_id = pr.product_id;


-- Checks how many rows are imported properly
SELECT 'dim_customers' AS table_name, COUNT(*) AS row_count FROM warehouse.dim_customers
UNION ALL
SELECT 'dim_products',                COUNT(*)              FROM warehouse.dim_products
UNION ALL
SELECT 'fact_orders',                 COUNT(*)              FROM warehouse.fact_orders;


-- Flag completed orders that are missing payment information.
ALTER TABLE warehouse.fact_orders
ADD COLUMN is_payment_missing BOOLEAN;

UPDATE warehouse.fact_orders
SET is_payment_missing = (amount IS NULL AND status = 'completed');

-- Count of orders with/without missing payment info
SELECT is_payment_missing, COUNT(*)
FROM warehouse.fact_orders
GROUP BY is_payment_missing;

--Total revenue and order count by product category 
SELECT
    p.category,
    SUM(f.revenue) AS total_revenue,
    COUNT(*)       AS total_orders
FROM warehouse.fact_orders f
JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.category
ORDER BY total_revenue DESC;

--Top 5 customers by total spend (window function)
SELECT customer_id, full_name, total_spent, customer_rank
FROM (
    SELECT
        c.customer_id,
        c.full_name,
        SUM(f.revenue) AS total_spent,
        RANK() OVER (ORDER BY SUM(f.revenue) DESC) AS customer_rank
    FROM warehouse.fact_orders f
    JOIN warehouse.dim_customers c ON f.customer_id = c.customer_id
    GROUP BY c.customer_id, c.full_name
) ranked
WHERE customer_rank <= 5;

--Monthly order count and revenue trend 
SELECT
    DATE_TRUNC('month', order_date) AS order_month,
    COUNT(*)                        AS total_orders,
    SUM(revenue)                    AS total_revenue
FROM warehouse.fact_orders
GROUP BY DATE_TRUNC('month', order_date)
ORDER BY order_month;

--Return rate by product (min. 3 orders to be included) 
SELECT
    p.title,
    COUNT(*) AS total_orders,
    SUM(CASE WHEN f.status = 'returned' THEN 1 ELSE 0 END) AS returned_orders,
    ROUND(
        100.0 * SUM(CASE WHEN f.status = 'returned' THEN 1 ELSE 0 END) / COUNT(*),
        2
    ) AS return_rate_percent
FROM warehouse.fact_orders f
JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.title
HAVING COUNT(*) >= 3
ORDER BY return_rate_percent DESC;

--Cohort analysis: customers by signup month + avg revenue/customer 
SELECT
    DATE_TRUNC('month', c.signup_date) AS signup_month,
    COUNT(DISTINCT c.customer_id)      AS customers,
    COALESCE(SUM(f.revenue), 0)        AS total_revenue,
    ROUND(
        COALESCE(SUM(f.revenue), 0) / COUNT(DISTINCT c.customer_id),
        2
    ) AS avg_revenue_per_customer
FROM warehouse.dim_customers c
LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY DATE_TRUNC('month', c.signup_date)
ORDER BY signup_month;

--Transaction count and amount by payment method 
SELECT
    method,
    COUNT(*)      AS total_transactions,
    SUM(amount)   AS total_amount
FROM warehouse.fact_orders
GROUP BY method
ORDER BY total_transactions DESC;

--Overall order value statistics 
SELECT
    ROUND(AVG(revenue), 2) AS average_order_value,
    MIN(revenue)            AS minimum_order,
    MAX(revenue)             AS maximum_order
FROM warehouse.fact_orders;

--Top 10 best-selling products by quantity 
SELECT
    p.title,
    SUM(f.quantity) AS total_quantity,
    SUM(f.revenue)  AS total_revenue
FROM warehouse.fact_orders f
JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.title
ORDER BY total_quantity DESC
LIMIT 10;

--Customer spending habits 
SELECT
    c.customer_id,
    c.full_name,
    COUNT(f.order_id) AS total_orders,
    SUM(f.revenue)     AS total_spent
FROM warehouse.dim_customers c
LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY c.customer_id, c.full_name
ORDER BY total_orders DESC;

-- Completed orders missing payment amount 
SELECT order_id, customer_id, status, amount
FROM warehouse.fact_orders
WHERE status = 'completed'
  AND amount IS NULL;

-- Gaps of 90+ days between a customer's consecutive orders 
WITH customer_orders AS (
    SELECT
        customer_id,
        order_date,
        order_date - LAG(order_date) OVER (
            PARTITION BY customer_id
            ORDER BY order_date
        ) AS gap_days
    FROM retail_store.orders
)
SELECT *
FROM customer_orders
WHERE gap_days > 90;

-- Payment-to-payment amount trend (chronological) 
SELECT
    payment_id,
    order_id,
    payment_date,
    amount,
    LEAD(payment_date) OVER (ORDER BY payment_date) AS next_payment_date,
    LEAD(amount)       OVER (ORDER BY payment_date) AS next_payment_amount,
    LEAD(amount)       OVER (ORDER BY payment_date) - amount AS payment_difference
FROM retail_store.payments;

-- Customer acquisition vs. retention 
WITH customer_orders AS (
    SELECT
        customer_id,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY order_date
        ) AS purchase_number
    FROM retail_store.orders
),
customer_summary AS (
    SELECT
        customer_id,
        MAX(purchase_number) AS total_orders
    FROM customer_orders
    GROUP BY customer_id
)
SELECT
    COUNT(*)                                            AS acquired_customers,
    COUNT(*) FILTER (WHERE total_orders >= 2)            AS retained_customers,
    COUNT(*) FILTER (WHERE total_orders = 1)             AS one_time_customers,
    ROUND(
        COUNT(*) FILTER (WHERE total_orders >= 2) * 100.0 / COUNT(*),
        2
    ) AS retention_rate_percent
FROM customer_summary;

-- Repeat purchase rate of customers
WITH customer_order_counts AS (
    SELECT
        customer_id,
        COUNT(*) AS order_count
    FROM warehouse.fact_orders
    GROUP BY customer_id
)
SELECT
    COUNT(*) AS total_customers,
    COUNT(*) FILTER (WHERE order_count > 1) AS repeat_customers,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE order_count > 1) / COUNT(*),
        2
    ) AS repeat_purchase_rate_percent
FROM customer_order_counts;

-- Order distribution by city
SELECT
    c.city,
    COUNT(DISTINCT c.customer_id) AS total_customers,
    COUNT(f.order_id) AS total_orders,
    COALESCE(SUM(f.revenue), 0) AS total_revenue,
    ROUND(
        COALESCE(SUM(f.revenue), 0) / NULLIF(COUNT(DISTINCT c.customer_id), 0),
        2
    ) AS avg_revenue_per_customer
FROM warehouse.dim_customers c
    LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
GROUP BY c.city
ORDER BY total_revenue DESC;

-- Customer Segmentation
WITH customer_totals AS (
    SELECT
        c.customer_id,
        c.full_name,
        COALESCE(SUM(f.revenue), 0) AS total_spent
    FROM warehouse.dim_customers c
        LEFT JOIN warehouse.fact_orders f ON c.customer_id = f.customer_id
    GROUP BY c.customer_id, c.full_name
)
SELECT
    customer_id,
    full_name,
    total_spent,
    NTILE(4) OVER (ORDER BY total_spent DESC) AS spend_quartile --NTILE(4) divides the customer into 4 equal segments
FROM customer_totals
ORDER BY total_spent DESC;

--The gap between signup date and the date of first order
WITH first_orders AS (
    SELECT
        customer_id,
        MIN(order_date) AS first_order_date
    FROM warehouse.fact_orders
    GROUP BY customer_id
)
SELECT
    c.customer_id,
    c.full_name,
    c.signup_date,
    fo.first_order_date,
    (fo.first_order_date - c.signup_date) AS days_to_first_order
FROM warehouse.dim_customers c
    JOIN first_orders fo ON c.customer_id = fo.customer_id
ORDER BY days_to_first_order DESC;

-- Order status breakdown per product category, with share of category orders
SELECT
    p.category,
    f.status,
    COUNT(*) AS order_count,
    ROUND(
        100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY p.category),
        2
    ) AS status_share_percent
FROM warehouse.fact_orders f
    JOIN warehouse.dim_products p ON f.product_id = p.product_id
GROUP BY p.category, f.status
ORDER BY p.category, order_count DESC;