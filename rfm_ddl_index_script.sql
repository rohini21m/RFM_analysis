CREATE SCHEMA IF NOT EXISTS RFM_analysis;

-- ==========================================
-- 1. CREATE DIMENSION: PRODUCTS (AmEx specific)
-- ==========================================
CREATE TABLE IF NOT EXISTS RFM_analysis.dim_products (
    product_code INT PRIMARY KEY, -- Cleaned naming scheme up-front
    product_name VARCHAR(100),
    credit_line DECIMAL(12,2),
    apr DECIMAL(5,2),
    cashback_pct DECIMAL(5,2)
);

-- Using INSERT ON CONFLICT to allow safe re-runs of the script
INSERT INTO RFM_analysis.dim_products (product_code, product_name, credit_line, apr, cashback_pct) 
VALUES 
    (101, 'Blue_Cash_Everyday_Card', 5000.00, 19.99, 3.00),
    (102, 'Blue_Cash_Preferred', 10000.00, 24.99, 6.00),
    (103, 'Amex_Platinum_Card', 25000.00, 0.00, 8.00),
    (104, 'Amex_Gold_Card', 15000.00, 0.00, 4.00)
ON CONFLICT (product_code) DO NOTHING;


-- ==========================================
-- 2. CREATE DIMENSION: CUSTOMERS (~30K profiles)
-- ==========================================
CREATE TABLE IF NOT EXISTS RFM_analysis.dim_customers (
    customer_id UUID PRIMARY KEY,
    customer_age INT,
    marital_status VARCHAR(20),
    customer_contact_no VARCHAR(20),
    customer_email VARCHAR(100),
    customer_birthdate DATE,
    state VARCHAR(50),
    city VARCHAR(50),
    country VARCHAR(50),
    zipcode VARCHAR(10)
);


-- ==========================================
-- 3. CREATE DIMENSION: ACCOUNTS (Links to Customers)
-- ==========================================
-- ==========================================
-- 2. CREATE DIMENSION: ACCOUNTS (Updated with Product Code)
-- ==========================================
CREATE TABLE IF NOT EXISTS RFM_analysis.dim_accounts (
    account_id UUID PRIMARY KEY,
    customer_id UUID REFERENCES RFM_analysis.dim_customers(customer_id),
    -- Added product_code here to declare what product this account uses
    product_code INT REFERENCES RFM_analysis.dim_products(product_code), 
    account_number VARCHAR(20) UNIQUE, 
    account_type VARCHAR(20), -- 'Credit Card', 'Checking', etc.
    account_start_date DATE,
    account_end_date DATE
);

-- ==========================================
-- ==========================================
-- 4. SEED THE DIMENSION DATA (30K Customers + Accounts)
-- ==========================================
WITH unique_rows AS (
    -- Step 1: Only generate data for account numbers that do NOT already exist in the database
    SELECT 
        gen_random_uuid() AS customer_id,
        gen_random_uuid() AS account_id,
        21 + (n % 55) AS customer_age,
        CASE (n % 3) WHEN 0 THEN 'Single' WHEN 1 THEN 'Married' ELSE 'Divorced' END AS marital_status,
        '+1-555-' || LPAD(CAST(1000 + (n % 50000) AS TEXT), 4, '0') AS customer_contact_no,
        'user_' || n || '@example.com' AS customer_email,
        CURRENT_DATE - INTERVAL '1 year' * (21 + (n % 55)) AS customer_birthdate,
        CASE (n % 5) WHEN 0 THEN 'New York' WHEN 1 THEN 'California' WHEN 2 THEN 'Texas' WHEN 3 THEN 'Florida' ELSE 'Illinois' END AS state,
        CASE (n % 5) WHEN 0 THEN 'New York City' WHEN 1 THEN 'Los Angeles' WHEN 2 THEN 'Houston' WHEN 3 THEN 'Miami' ELSE 'Chicago' END AS city,
        'United States' AS country,
        LPAD(CAST(10001 + (n % 80000) AS TEXT), 5, '0') AS zipcode,
        'AMEX-' || LPAD(CAST(n AS TEXT), 8, '0') AS account_number,
        CASE (n % 2) WHEN 0 THEN 'Credit Card' ELSE 'Checking' END AS account_type,
        101 + (n % 4) AS product_code, 
        CURRENT_DATE - INTERVAL '1 day' * (30 + (n % 700)) AS account_start_date
    FROM generate_series(1, 30000) AS n
    WHERE NOT EXISTS (
        SELECT 1 FROM RFM_analysis.dim_accounts a 
        WHERE a.account_number = 'AMEX-' || LPAD(CAST(n AS TEXT), 8, '0')
    )
),
inserted_customers AS (
    -- Step 2: Insert unique customers into the dimension table
    INSERT INTO RFM_analysis.dim_customers (
        customer_id, customer_age, marital_status, customer_contact_no, 
        customer_email, customer_birthdate, state, city, country, zipcode
    )
    SELECT 
        customer_id, customer_age, marital_status, customer_contact_no, 
        customer_email, customer_birthdate, state, city, country, zipcode
    FROM unique_rows
    RETURNING customer_id
)
-- Step 3: Insert matching unique accounts safely
INSERT INTO RFM_analysis.dim_accounts (
    account_id, customer_id, product_code, account_number, account_type, account_start_date, account_end_date
)
SELECT 
    u.account_id,
    u.customer_id,
    u.product_code,
    u.account_number,
    u.account_type,
    u.account_start_date,
    NULL AS account_end_date
FROM unique_rows u
WHERE u.customer_id IN (SELECT customer_id FROM inserted_customers);

-- ==========================================
-- 5. CREATE FACT TABLE: TRANSACTIONS (Targeting 800K rows)
-- ==========================================
CREATE TABLE IF NOT EXISTS RFM_analysis.fact_transactions (
    id SERIAL PRIMARY KEY,
    account_id UUID, -- Updated target column to follow account architecture
    product_code INT,
    merchant_code VARCHAR(50),
    credit_card_number VARCHAR(15),
    transaction_id UUID,
    transaction_amt DECIMAL(10,2),
    transaction_date DATE,
    trx_timestamp TIMESTAMP,
    location VARCHAR(100),
    ip_address VARCHAR(45),
    credit_line DECIMAL(12,2),
    fees DECIMAL(10,2),
    interest DECIMAL(10,2),
    credits DECIMAL(10,2),
    previous_balance DECIMAL(12,2),
    status INT,
    
    -- Clean explicit foreign key constraints 
    CONSTRAINT fk_fact_transactions_accounts FOREIGN KEY (account_id) REFERENCES RFM_analysis.dim_accounts(account_id),
    CONSTRAINT fk_fact_transactions_products FOREIGN KEY (product_code) REFERENCES RFM_analysis.dim_products(product_code)
);


-- ==========================================
-- 6. HIGH-SPEED IN-MEMORY DATA POPULATION (800K)
-- ========================================== 

--script1 : 
-- ==========================================
-- REVISED HIGH-SPEED IN-MEMORY DATA POPULATION 
-- Features: Variable transaction counts (5 to 15 per account) 
-- and Clustered/Sparse Date Distribution (Burst activity, gaps in-between)
-- ==========================================

WITH account_transaction_targets AS (
    -- Assigns a randomized transaction count between 5 and 15 per account
    SELECT 
        a.account_id, 
        a.account_number, 
        a.product_code, 
        c.city, 
        c.state, 
        5 + (ABS(HASHTEXT(a.account_number)) % 11) AS target_trx_count
    FROM RFM_analysis.dim_accounts a
    JOIN RFM_analysis.dim_customers c ON a.customer_id = c.customer_id
), 
expanded_sequence AS (
    -- Expands each account into its specific subset of transaction rows
    SELECT 
        act.account_id,
        act.account_number,
        act.product_code,
        act.city,
        act.state,
        s.n AS seq_n
    FROM account_transaction_targets act
    CROSS JOIN LATERAL generate_series(1, act.target_trx_count) s(n)
)
INSERT INTO RFM_analysis.fact_transactions (
    account_id, 
    product_code, 
    merchant_code, 
    merchant_code_description,
    credit_card_number, 
    trnx_id, 
    trnx_amt, 
    trnx_date, 
    trx_timestamp, 
    location_zipcode, 
    ip_address,
    credit_line,
    fees, 
    interest, 
    credits, 
    previous_balance, 
    status
)
SELECT 
    seq.account_id,
    seq.product_code,
    
    -- 1. Merchant Code Mapping
    CASE (seq.seq_n % 16)
        WHEN 0 THEN '9135' WHEN 1 THEN '9136' WHEN 2 THEN '9137' WHEN 3 THEN '9138'
        WHEN 4 THEN '9139' WHEN 5 THEN '9140' WHEN 6 THEN '9141' WHEN 7 THEN '9142'
        WHEN 8 THEN '9143' WHEN 9 THEN '9144' WHEN 10 THEN '9145' WHEN 11 THEN '9146'
        WHEN 12 THEN '9147' WHEN 13 THEN '9148' WHEN 14 THEN '9149' ELSE '9150'
    END AS merchant_code,
    
    -- 2. Merchant Description Mapping
    CASE (seq.seq_n % 16)
        WHEN 0 THEN 'Merchandise & Supplies - Groceries'
        WHEN 1 THEN 'Merchandise & Supplies - Department Stores'
        WHEN 2 THEN 'Other - Charities'
        WHEN 3 THEN 'Other - Religious Food Stores'
        WHEN 4 THEN 'Merchandise & Supplies - Clothing Stores'
        WHEN 5 THEN 'Merchandise & Supplies - Wholesale - Stores(Target)'
        WHEN 6 THEN 'Fees & Adjustments - fees & Adjustments (rewards/refund)'
        WHEN 7 THEN 'Merchandise & Supplies - Hardware Supplies'
        WHEN 8 THEN 'Business Services - Contracting Services'
        WHEN 9 THEN 'Restaurant - Restaurant'
        WHEN 10 THEN 'Transportation - Rail Services'
        WHEN 11 THEN 'Transportation - Parking Charges'
        WHEN 12 THEN 'Restaurant - Bar & Cafe'
        WHEN 13 THEN 'Transportation - Airlines Services'
        WHEN 14 THEN 'Entertainment - Movies'
        ELSE 'Merchandise & Supplies - Medical Services'
    END AS merchant_code_description,

    '37' || LPAD(CAST((ABS(HASHTEXT(seq.account_number || seq.seq_n)) % 10000000000001) AS TEXT), 13, '0') AS credit_card_number, 
    gen_random_uuid() AS trnx_id, 
    ROUND(CAST(10.00 + (RANDOM() * 1490.00) AS NUMERIC), 2) AS trnx_amt, 
    
    -- 3. Clustered Date Logic: Skips weeks, forces bursts (First 2 weeks vs Last 2 weeks of a monthly window)
    ('2024-12-01'::date + INTERVAL '1 day' * (
        CASE 
            WHEN (ABS(HASHTEXT(seq.account_number || seq.seq_n)) % 2) = 0 
                THEN (ABS(HASHTEXT(seq.seq_n::text)) % 14) -- First 2 weeks burst (Days 0-13)
            ELSE 
                15 + (ABS(HASHTEXT(seq.seq_n::text)) % 15) -- Last 2 weeks burst (Days 15-29)
        END + (30 * (ABS(HASHTEXT(seq.account_number)) % 14)) -- Shifts across the 14-month window
    )) AS trnx_date, 
    
    CURRENT_TIMESTAMP - INTERVAL '1 minute' * (seq.seq_n % 525600) AS trx_timestamp, 
    
    -- 4. Geographic Zip Codes Across NY, NC, TX, MA, AZ
    CASE (seq.seq_n % 5)
        WHEN 0 THEN CAST(FLOOR(10001 + (RANDOM() * 483)) AS TEXT) 
        WHEN 1 THEN CAST(FLOOR(27001 + (RANDOM() * 800)) AS TEXT) 
        WHEN 2 THEN CAST(FLOOR(75001 + (RANDOM() * 999)) AS TEXT) 
        WHEN 3 THEN '0' || CAST(FLOOR(1001 + (RANDOM() * 1200)) AS TEXT) 
        ELSE CAST(FLOOR(85001 + (RANDOM() * 500)) AS TEXT) 
    END AS location_zipcode, 
    
    '192.168.' || (seq.seq_n % 255) || '.' || ((seq.seq_n * 7) % 255) AS ip_address, 
    'Credit_card' AS credit_line, 
    CASE WHEN (seq.seq_n % 10) = 0 THEN 39.00 ELSE 0.00 END AS fees, 
    CASE WHEN (seq.seq_n % 8) = 0 THEN ROUND(CAST((RANDOM() * 50.00) AS NUMERIC), 2) ELSE 0.00 END AS interest, 
    CASE WHEN (seq.seq_n % 4) = 0 THEN ROUND(CAST((RANDOM() * 200.00) AS NUMERIC), 2) ELSE 0.00 END AS credits, 
    ROUND(CAST((RANDOM() * 3000.00) AS NUMERIC), 2) AS previous_balance, 
    
    CASE 
        WHEN (seq.seq_n % 50) = 0 THEN 'DUPLICATE_BATCH' 
        WHEN (seq.seq_n % 20) = 0 THEN 'CHARGEBACK_PROCESSED' 
        WHEN (seq.seq_n % 5) = 0 THEN 'DECLINED' 
        ELSE 'APPROVED' 
    END AS status 
FROM expanded_sequence seq;
--script 2 :
WITH indexed_accounts AS (
    SELECT 
        a.account_id, 
        a.account_number, 
        a.product_code, 
        c.city, 
        c.state, 
        ROW_NUMBER() OVER (ORDER BY a.account_id) AS account_idx
    FROM RFM_analysis.dim_accounts a
    JOIN RFM_analysis.dim_customers c ON a.customer_id = c.customer_id
), 
seq_generator AS (
    SELECT generate_series AS n FROM generate_series(1, 800000)
)
INSERT INTO RFM_analysis.fact_transactions (
    account_id, 
    product_code, 
    merchant_code, 
    merchant_code_description,
    credit_card_number, 
    trnx_id, 
    trnx_amt, 
    trnx_date, 
    trx_timestamp, 
    location_zipcode, 
    ip_address,
    credit_line,
    fees, 
    interest, 
    credits, 
    previous_balance, 
    status
)
SELECT 
    a.account_id,
    a.product_code,
    
    -- 1. Merchant Code Mapping
    CASE (seq.n % 16)
        WHEN 0 THEN '9135' WHEN 1 THEN '9136' WHEN 2 THEN '9137' WHEN 3 THEN '9138'
        WHEN 4 THEN '9139' WHEN 5 THEN '9140' WHEN 6 THEN '9141' WHEN 7 THEN '9142'
        WHEN 8 THEN '9143' WHEN 9 THEN '9144' WHEN 10 THEN '9145' WHEN 11 THEN '9146'
        WHEN 12 THEN '9147' WHEN 13 THEN '9148' WHEN 14 THEN '9149' ELSE '9150'
    END AS merchant_code,
    
    -- 2. Merchant Description Mapping
    CASE (seq.n % 16)
        WHEN 0 THEN 'Merchandise & Supplies - Groceries'
        WHEN 1 THEN 'Merchandise & Supplies - Department Stores'
        WHEN 2 THEN 'Other - Charities'
        WHEN 3 THEN 'Other - Religious Food Stores'
        WHEN 4 THEN 'Merchandise & Supplies - Clothing Stores'
        WHEN 5 THEN 'Merchandise & Supplies - Wholesale - Stores(Target)'
        WHEN 6 THEN 'Fees & Adjustments - fees & Adjustments (rewards/refund)'
        WHEN 7 THEN 'Merchandise & Supplies - Hardware Supplies'
        WHEN 8 THEN 'Business Services - Contracting Services'
        WHEN 9 THEN 'Restaurant - Restaurant'
        WHEN 10 THEN 'Transportation - Rail Services'
        WHEN 11 THEN 'Transportation - Parking Charges'
        WHEN 12 THEN 'Restaurant - Bar & Cafe'
        WHEN 13 THEN 'Transportation - Airlines Services'
        WHEN 14 THEN 'Entertainment - Movies'
        ELSE 'Merchandise & Supplies - Medical Services'
    END AS merchant_code_description,

    '37' || LPAD(CAST((ABS(HASHTEXT(a.account_number || seq.n)) % 10000000000001) AS TEXT), 13, '0') AS credit_card_number, 
    gen_random_uuid() AS trnx_id, 
    ROUND(CAST(10.00 + (RANDOM() * 1490.00) AS NUMERIC), 2) AS trnx_amt, 
    
    -- 3. Clustered Date Logic: Burst activity in first 2 weeks or last 2 weeks with gaps across the 14-month window
    ('2024-12-01'::date + INTERVAL '1 day' * (
        CASE 
            WHEN (ABS(HASHTEXT(a.account_number || seq.n)) % 2) = 0 
                THEN (ABS(HASHTEXT(seq.n::text)) % 14) -- First 2 weeks burst (Days 0-13)
            ELSE 
                15 + (ABS(HASHTEXT(seq.n::text)) % 15) -- Last 2 weeks burst (Days 15-29)
        END + (30 * (ABS(HASHTEXT(a.account_number || seq.n)) % 14)) -- Shifts across the 14-month window
    )) AS trnx_date, 
    
    CURRENT_TIMESTAMP - INTERVAL '1 minute' * (seq.n % 525600) AS trx_timestamp, 
    
    -- 4. Geographic Zip Codes Across NY, NC, TX, MA, AZ
    CASE (seq.n % 5)
        WHEN 0 THEN CAST(FLOOR(10001 + (RANDOM() * 483)) AS TEXT) 
        WHEN 1 THEN CAST(FLOOR(27001 + (RANDOM() * 800)) AS TEXT) 
        WHEN 2 THEN CAST(FLOOR(75001 + (RANDOM() * 999)) AS TEXT) 
        WHEN 3 THEN '0' || CAST(FLOOR(1001 + (RANDOM() * 1200)) AS TEXT) 
        ELSE CAST(FLOOR(85001 + (RANDOM() * 500)) AS TEXT) 
    END AS location_zipcode, 
    
    '192.168.' || (seq.n % 255) || '.' || ((seq.n * 7) % 255) AS ip_address, 
    'Credit_card' AS credit_line, 
    CASE WHEN (seq.n % 10) = 0 THEN 39.00 ELSE 0.00 END AS fees, 
    CASE WHEN (seq.n % 8) = 0 THEN ROUND(CAST((RANDOM() * 50.00) AS NUMERIC), 2) ELSE 0.00 END AS interest, 
    CASE WHEN (seq.n % 4) = 0 THEN ROUND(CAST((RANDOM() * 200.00) AS NUMERIC), 2) ELSE 0.00 END AS credits, 
    ROUND(CAST((RANDOM() * 3000.00) AS NUMERIC), 2) AS previous_balance, 
    
    CASE 
        WHEN (seq.n % 50) = 0 THEN 'DUPLICATE_BATCH' 
        WHEN (seq.n % 20) = 0 THEN 'CHARGEBACK_PROCESSED' 
        WHEN (seq.n % 5) = 0 THEN 'DECLINED' 
        ELSE 'APPROVED' 
    END AS status 
FROM seq_generator seq
-- Distributes the exact 800,000 sequence rows unevenly across the 30,000 accounts using a prime multiplier offset
JOIN indexed_accounts a ON a.account_idx = ((seq.n * 17) % 30000) + 1; 



-- ==========================================
-- 7. PRODUCTION-READY HIGH PERFORMANCE INDEXES
-- ==========================================

-- FK and Join Performance Optimization Indexes
CREATE INDEX idx_fact_trx_account_id ON RFM_analysis.fact_transactions (account_id);
CREATE INDEX idx_fact_trx_product_code ON RFM_analysis.fact_transactions (product_code);
CREATE INDEX idx_dim_accounts_customer_id ON RFM_analysis.dim_accounts (customer_id);

-- Speed up filtering by transaction dates & processing status for RFM extraction scripts
CREATE INDEX idx_fact_trx_date_status ON RFM_analysis.fact_transactions (transaction_date, status);

-- Composite Index for analyzing a single active Account's sequential spending trends
CREATE INDEX idx_fact_trx_acct_date ON RFM_analysis.fact_transactions (account_id, transaction_date);

select * from RFM_analysis.fact_transactions 
limit 100
-- Analytical Geography Index for regional segmentation dashboards
CREATE INDEX idx_dim_customers_geo ON RFM_analysis.dim_customers (country, state, city);

CREATE INDEX idx_dim_accounts_product_code ON RFM_analysis.dim_accounts (product_code);

-- dropping the table columns which are redundant

-- 2. Remove the redundant credit line column
ALTER TABLE rfm_analysis.fact_transactions 
DROP COLUMN credit_line; 

select product_code, count(account_id) as accounts_per_product_line
from RFM_analysis.fact_transactions 
group by product_code

select distinct product_code--, count(account_id) as accounts_per_product_line
from RFM_analysis.fact_transactions

drop table RFM_analysis.fact_transactions
