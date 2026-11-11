-- Stored procedures and views called by the SSIS packages.
USE LoanDW;
GO

------------------------------------------------------------------ batch logging
CREATE OR ALTER PROCEDURE etl.usp_batch_start
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.batch_run DEFAULT VALUES;
    SELECT CAST(SCOPE_IDENTITY() AS int) AS batch_id;
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_batch_end
    @batch_id int,
    @status varchar(10),
    @error_message nvarchar(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE etl.batch_run
    SET finished_at = SYSDATETIME(), status = @status, error_message = @error_message
    WHERE batch_id = @batch_id;
END;
GO

---------------------------------------------------------------------- watermark
CREATE OR ALTER PROCEDURE etl.usp_get_watermark
    @table_name varchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT last_updated_at FROM etl.watermark WHERE table_name = @table_name;
END;
GO

-- Called after staging succeeds. Moves each watermark to the newest row staged.
CREATE OR ALTER PROCEDURE etl.usp_update_watermarks
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE w
    SET last_updated_at = s.max_updated_at
    FROM etl.watermark AS w
    JOIN (
        SELECT 'branch' AS table_name, MAX(updated_at) AS max_updated_at FROM stg.branch
        UNION ALL SELECT 'product', MAX(updated_at) FROM stg.product
        UNION ALL SELECT 'customer', MAX(updated_at) FROM stg.customer
        UNION ALL SELECT 'loan', MAX(updated_at) FROM stg.loan
    ) AS s ON s.table_name = w.table_name
    WHERE s.max_updated_at > w.last_updated_at;
END;
GO

----------------------------------------------------------------------- dim_date
CREATE OR ALTER PROCEDURE etl.usp_load_dim_date
    @start_date date = '2022-01-01',
    @end_date date = '2030-12-31'  -- covers the maturity of a 48-month loan disbursed in 2026
AS
BEGIN
    SET NOCOUNT ON;
    WITH days AS (
        SELECT DATEADD(day, n, @start_date) AS d
        FROM (
            SELECT TOP (DATEDIFF(day, @start_date, @end_date) + 1)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
            FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
        ) AS numbers
    )
    INSERT INTO dw.dim_date (date_key, full_date, year, quarter, month, month_name, year_month,
                             day_of_month, day_of_week, day_name, is_weekend, is_month_end)
    SELECT
        YEAR(d) * 10000 + MONTH(d) * 100 + DAY(d),
        d,
        YEAR(d),
        DATEPART(quarter, d),
        MONTH(d),
        CHOOSE(MONTH(d), N'Januari', N'Februari', N'Maret', N'April', N'Mei', N'Juni', N'Juli',
               N'Agustus', N'September', N'Oktober', N'November', N'Desember'),
        CONVERT(char(7), d, 126),
        DAY(d),
        dow.n,
        CHOOSE(dow.n, N'Senin', N'Selasa', N'Rabu', N'Kamis', N'Jumat', N'Sabtu', N'Minggu'),
        CASE WHEN dow.n IN (6, 7) THEN 1 ELSE 0 END,
        CASE WHEN d = EOMONTH(d) THEN 1 ELSE 0 END
    FROM days
    -- Monday = 1 whatever the server's DATEFIRST setting is. 1900-01-01 was a Monday.
    CROSS APPLY (SELECT DATEDIFF(day, '1900-01-01', d) % 7 + 1 AS n) AS dow
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_date AS x WHERE x.full_date = days.d);
END;
GO

-------------------------------------------------------------- SCD 1 dimensions
CREATE OR ALTER PROCEDURE etl.usp_load_dim_branch
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.dim_branch AS t
    USING stg.branch AS s ON t.branch_id = s.branch_id
    WHEN MATCHED THEN UPDATE SET
        branch_name = s.branch_name, city = s.city, province = s.province,
        region = s.region, opened_date = s.opened_date
    WHEN NOT MATCHED THEN
        INSERT (branch_id, branch_name, city, province, region, opened_date)
        VALUES (s.branch_id, s.branch_name, s.city, s.province, s.region, s.opened_date);
END;
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_product
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.dim_product AS t
    USING stg.product AS s ON t.product_id = s.product_id
    WHEN MATCHED THEN UPDATE SET
        product_name = s.product_name, category = s.category, interest_rate_flat = s.interest_rate_flat
    WHEN NOT MATCHED THEN
        INSERT (product_id, product_name, category, interest_rate_flat)
        VALUES (s.product_id, s.product_name, s.category, s.interest_rate_flat);
END;
GO

----------------------------------------------------------- SCD 2 dim_customer
-- Occupation, income, city, and province are tracked as history (Type 2).
-- Name, gender, and birth date are corrections, so they overwrite every version (Type 1).
CREATE OR ALTER PROCEDURE etl.usp_load_dim_customer
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DROP TABLE IF EXISTS #src;
    SELECT
        customer_id, full_name, gender, birth_date, occupation, monthly_income, city, province,
        CASE
            WHEN monthly_income < 5000000 THEN N'< 5 juta'
            WHEN monthly_income < 10000000 THEN N'5-10 juta'
            ELSE N'> 10 juta'
        END AS income_band,
        CAST(created_at AS date) AS created_date,
        CAST(updated_at AS date) AS updated_date,
        HASHBYTES('SHA2_256', CONCAT_WS(N'|', occupation, monthly_income, city, province)) AS row_hash
    INTO #src
    FROM stg.customer;

    BEGIN TRANSACTION;

    -- Type 1 corrections on all versions.
    UPDATE d
    SET full_name = s.full_name, gender = s.gender, birth_date = s.birth_date
    FROM dw.dim_customer AS d
    JOIN #src AS s ON s.customer_id = d.customer_id
    WHERE d.full_name <> s.full_name OR d.gender <> s.gender OR ISNULL(d.birth_date, '1900-01-01') <> s.birth_date;

    -- Customers whose tracked attributes changed. A change on the same day the current
    -- version started gets the next day, so validity ranges never overlap.
    DROP TABLE IF EXISTS #changed;
    SELECT
        d.customer_key,
        s.customer_id,
        CASE WHEN s.updated_date > d.valid_from THEN s.updated_date ELSE DATEADD(day, 1, d.valid_from) END AS new_valid_from
    INTO #changed
    FROM #src AS s
    JOIN dw.dim_customer AS d ON d.customer_id = s.customer_id AND d.is_current = 1
    WHERE d.row_hash <> s.row_hash;

    -- Close the current version.
    UPDATE d
    SET valid_to = DATEADD(day, -1, c.new_valid_from), is_current = 0
    FROM dw.dim_customer AS d
    JOIN #changed AS c ON c.customer_key = d.customer_key;

    -- New version for changed customers, first version for new customers.
    INSERT INTO dw.dim_customer (customer_id, full_name, gender, birth_date, occupation, monthly_income,
                                 income_band, city, province, valid_from, valid_to, is_current, row_hash)
    SELECT
        s.customer_id, s.full_name, s.gender, s.birth_date, s.occupation, s.monthly_income,
        s.income_band, s.city, s.province,
        COALESCE(c.new_valid_from, s.created_date),
        '9999-12-31', 1, s.row_hash
    FROM #src AS s
    LEFT JOIN #changed AS c ON c.customer_id = s.customer_id
    WHERE c.customer_id IS NOT NULL
       OR NOT EXISTS (SELECT 1 FROM dw.dim_customer AS d WHERE d.customer_id = s.customer_id);

    COMMIT TRANSACTION;
END;
GO

---------------------------------------------------------------------- fact_loan
CREATE OR ALTER PROCEDURE etl.usp_load_fact_loan
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dw.fact_loan AS t
    USING (
        SELECT
            l.loan_id,
            -- The customer version valid on the disbursement date (point-in-time lookup).
            COALESCE(pit.customer_key, cur.customer_key, -1) AS customer_key,
            COALESCE(b.branch_key, -1) AS branch_key,
            COALESCE(p.product_key, -1) AS product_key,
            YEAR(l.application_date) * 10000 + MONTH(l.application_date) * 100 + DAY(l.application_date) AS application_date_key,
            YEAR(l.disbursement_date) * 10000 + MONTH(l.disbursement_date) * 100 + DAY(l.disbursement_date) AS disbursement_date_key,
            YEAR(m.maturity) * 10000 + MONTH(m.maturity) * 100 + DAY(m.maturity) AS maturity_date_key,
            l.disbursement_date,
            l.tenor_months,
            l.interest_rate_flat,
            l.principal_amount,
            ROUND(l.principal_amount * l.interest_rate_flat * l.tenor_months / 12, 0) AS interest_amount,
            l.installment_amount
        FROM stg.loan AS l
        CROSS APPLY (SELECT DATEADD(month, l.tenor_months, l.disbursement_date) AS maturity) AS m
        LEFT JOIN dw.dim_customer AS pit
            ON pit.customer_id = l.customer_id AND l.disbursement_date BETWEEN pit.valid_from AND pit.valid_to
        LEFT JOIN dw.dim_customer AS cur
            ON cur.customer_id = l.customer_id AND cur.is_current = 1
        LEFT JOIN dw.dim_branch AS b ON b.branch_id = l.branch_id
        LEFT JOIN dw.dim_product AS p ON p.product_id = l.product_id
    ) AS s ON t.loan_id = s.loan_id
    WHEN MATCHED THEN UPDATE SET
        customer_key = s.customer_key, branch_key = s.branch_key, product_key = s.product_key,
        application_date_key = s.application_date_key, disbursement_date_key = s.disbursement_date_key,
        maturity_date_key = s.maturity_date_key, disbursement_date = s.disbursement_date,
        tenor_months = s.tenor_months, interest_rate_flat = s.interest_rate_flat,
        principal_amount = s.principal_amount, interest_amount = s.interest_amount,
        installment_amount = s.installment_amount
    WHEN NOT MATCHED THEN
        INSERT (loan_id, customer_key, branch_key, product_key, application_date_key, disbursement_date_key,
                maturity_date_key, disbursement_date, tenor_months, interest_rate_flat, principal_amount,
                interest_amount, installment_amount)
        VALUES (s.loan_id, s.customer_key, s.branch_key, s.product_key, s.application_date_key,
                s.disbursement_date_key, s.maturity_date_key, s.disbursement_date, s.tenor_months,
                s.interest_rate_flat, s.principal_amount, s.interest_amount, s.installment_amount);
END;
GO

------------------------------------------------------------------- fact_payment
-- Staged payments not yet in the warehouse, one row per payment_id.
-- This is the source of the SSIS data flow that loads dw.fact_payment.
CREATE OR ALTER VIEW etl.vw_payment_to_load
AS
SELECT payment_id, loan_id, installment_no, payment_date, amount, channel, source_file
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY loaded_at, source_file) AS rn
    FROM stg.payment
) AS p
WHERE rn = 1
  AND NOT EXISTS (SELECT 1 FROM dw.fact_payment AS f WHERE f.payment_id = p.payment_id);
GO

-- Lookup reference for the data flow: loan_id to its keys and the customer it belongs to.
CREATE OR ALTER VIEW etl.vw_loan_lookup
AS
SELECT l.loan_id, l.loan_key, l.branch_key, l.product_key, l.disbursement_date, c.customer_id
FROM dw.fact_loan AS l
JOIN dw.dim_customer AS c ON c.customer_key = l.customer_key;
GO

-- Logs payments that the view above skips: repeated payment_ids and ones already loaded.
CREATE OR ALTER PROCEDURE etl.usp_reject_duplicate_payments
    @batch_id int = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.payment_reject (payment_id, loan_id, installment_no, payment_date, amount, channel,
                                    source_file, reject_reason, batch_id)
    SELECT payment_id, loan_id, CAST(installment_no AS varchar(50)), CONVERT(varchar(50), payment_date, 23),
           CAST(amount AS varchar(50)), channel, source_file,
           CASE WHEN rn > 1 THEN N'Duplicate payment_id in staged files' ELSE N'payment_id already loaded' END,
           @batch_id
    FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY loaded_at, source_file) AS rn
        FROM stg.payment
    ) AS p
    WHERE rn > 1
       OR EXISTS (SELECT 1 FROM dw.fact_payment AS f WHERE f.payment_id = p.payment_id);
END;
GO

------------------------------------------------------- monthly loan snapshot
-- Rebuilds one row per active loan per month end, with days past due and the
-- OJK collectibility grade. Rebuilding the whole table keeps reruns idempotent.
CREATE OR ALTER PROCEDURE etl.usp_build_loan_snapshot
    @as_of_date date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Default: the month end of the latest payment received.
    SET @as_of_date = EOMONTH(COALESCE(@as_of_date,
        (SELECT MAX(d.full_date) FROM dw.fact_payment AS f JOIN dw.dim_date AS d ON d.date_key = f.payment_date_key)));
    DECLARE @first_month date = EOMONTH((SELECT MIN(disbursement_date) FROM dw.fact_loan));

    BEGIN TRANSACTION;
    TRUNCATE TABLE dw.fact_loan_monthly_snapshot;

    WITH base AS (
        SELECT
            m.date_key AS snapshot_date_key,
            m.full_date AS month_end,
            l.loan_key, l.customer_key, l.branch_key, l.product_key,
            l.principal_amount, l.tenor_months, l.disbursement_date,
            paid.installments_paid
        FROM dw.dim_date AS m
        JOIN dw.fact_loan AS l ON l.disbursement_date <= m.full_date
        CROSS APPLY (
            SELECT COUNT(DISTINCT p.installment_no) AS installments_paid
            FROM dw.fact_payment AS p
            WHERE p.loan_key = l.loan_key AND p.payment_date_key <= m.date_key
        ) AS paid
        WHERE m.is_month_end = 1
          AND m.full_date BETWEEN @first_month AND @as_of_date
    ),
    graded AS (
        SELECT
            b.*,
            -- Installments are paid in order, so the oldest unpaid one is number paid + 1.
            CASE
                WHEN DATEADD(month, b.installments_paid + 1, b.disbursement_date) <= b.month_end
                THEN DATEDIFF(day, DATEADD(month, b.installments_paid + 1, b.disbursement_date), b.month_end)
                ELSE 0
            END AS days_past_due
        FROM base AS b
        WHERE b.installments_paid < b.tenor_months  -- fully paid loans drop out
    )
    INSERT INTO dw.fact_loan_monthly_snapshot (snapshot_date_key, loan_key, customer_key, branch_key, product_key,
                                               installments_paid, outstanding_principal, days_past_due,
                                               collectibility, collectibility_label, is_npl)
    SELECT
        g.snapshot_date_key, g.loan_key,
        -- The customer version valid at that month end.
        COALESCE(pit.customer_key, g.customer_key),
        g.branch_key, g.product_key, g.installments_paid,
        ROUND(g.principal_amount * (g.tenor_months - g.installments_paid) / g.tenor_months, 0),
        g.days_past_due,
        k.collectibility,
        CHOOSE(k.collectibility, N'Lancar', N'Dalam Perhatian Khusus', N'Kurang Lancar', N'Diragukan', N'Macet'),
        CASE WHEN k.collectibility >= 3 THEN 1 ELSE 0 END
    FROM graded AS g
    JOIN dw.dim_customer AS c ON c.customer_key = g.customer_key
    LEFT JOIN dw.dim_customer AS pit
        ON pit.customer_id = c.customer_id AND g.month_end BETWEEN pit.valid_from AND pit.valid_to
    -- OJK collectibility by days past due.
    CROSS APPLY (SELECT CASE
        WHEN g.days_past_due = 0 THEN 1
        WHEN g.days_past_due <= 90 THEN 2
        WHEN g.days_past_due <= 120 THEN 3
        WHEN g.days_past_due <= 180 THEN 4
        ELSE 5 END AS collectibility) AS k;

    COMMIT TRANSACTION;
END;
GO
