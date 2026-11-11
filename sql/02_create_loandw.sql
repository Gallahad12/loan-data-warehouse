-- LoanDW: staging, ETL control tables, and the star schema.
IF DB_ID('LoanDW') IS NULL
    CREATE DATABASE LoanDW;
GO
-- Readers use row versions instead of shared locks, so an SSIS source reading a table
-- does not block the fast-load bulk insert into that same table.
ALTER DATABASE LoanDW SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
USE LoanDW;
GO

IF SCHEMA_ID('stg') IS NULL EXEC ('CREATE SCHEMA stg');
IF SCHEMA_ID('etl') IS NULL EXEC ('CREATE SCHEMA etl');
IF SCHEMA_ID('dw') IS NULL EXEC ('CREATE SCHEMA dw');
GO

DROP TABLE IF EXISTS dw.fact_loan_monthly_snapshot;
DROP TABLE IF EXISTS dw.fact_payment;
DROP TABLE IF EXISTS dw.fact_loan;
DROP TABLE IF EXISTS dw.dim_customer;
DROP TABLE IF EXISTS dw.dim_product;
DROP TABLE IF EXISTS dw.dim_branch;
DROP TABLE IF EXISTS dw.dim_date;
DROP TABLE IF EXISTS stg.branch;
DROP TABLE IF EXISTS stg.product;
DROP TABLE IF EXISTS stg.customer;
DROP TABLE IF EXISTS stg.loan;
DROP TABLE IF EXISTS stg.payment;
DROP TABLE IF EXISTS etl.payment_reject;
DROP TABLE IF EXISTS etl.file_log;
DROP TABLE IF EXISTS etl.watermark;
DROP TABLE IF EXISTS etl.batch_run;
GO

-------------------------------------------------------------------- ETL control
CREATE TABLE etl.batch_run (
    batch_id       int IDENTITY(1, 1) PRIMARY KEY,
    started_at     datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
    finished_at    datetime2(0)   NULL,
    status         varchar(10)    NOT NULL DEFAULT 'RUNNING',  -- RUNNING, SUCCESS, FAILED
    error_message  nvarchar(4000) NULL
);

-- Highest updated_at already extracted from each LoanCore table.
CREATE TABLE etl.watermark (
    table_name       varchar(50)  NOT NULL PRIMARY KEY,
    last_updated_at  datetime2(0) NOT NULL
);
INSERT INTO etl.watermark (table_name, last_updated_at)
VALUES ('branch', '1900-01-01'), ('product', '1900-01-01'), ('customer', '1900-01-01'), ('loan', '1900-01-01');

-- Payment files already loaded, so a file is never loaded twice.
CREATE TABLE etl.file_log (
    file_name     nvarchar(260) NOT NULL PRIMARY KEY,
    row_count     int           NOT NULL,
    batch_id      int           NULL,
    processed_at  datetime2(0)  NOT NULL DEFAULT SYSDATETIME()
);

-- Payment rows that could not be loaded, kept for follow-up instead of failing the run.
CREATE TABLE etl.payment_reject (
    reject_id       int IDENTITY(1, 1) PRIMARY KEY,
    payment_id      varchar(50)   NULL,
    loan_id         varchar(50)   NULL,
    installment_no  varchar(50)   NULL,
    payment_date    varchar(50)   NULL,
    amount          varchar(50)   NULL,
    channel         varchar(50)   NULL,
    source_file     nvarchar(260) NULL,
    reject_reason   nvarchar(200) NOT NULL,
    batch_id        int           NULL,
    rejected_at     datetime2(0)  NOT NULL DEFAULT SYSDATETIME()
);
GO

------------------------------------------------------------------------ staging
-- Truncated and reloaded each run with only the rows changed since the watermark.
CREATE TABLE stg.branch (
    branch_id varchar(10), branch_name nvarchar(100), city nvarchar(50), province nvarchar(50),
    region nvarchar(50), opened_date date, updated_at datetime2(0)
);
CREATE TABLE stg.product (
    product_id varchar(10), product_name nvarchar(100), category nvarchar(50),
    interest_rate_flat decimal(5, 4), updated_at datetime2(0)
);
CREATE TABLE stg.customer (
    customer_id varchar(12), full_name nvarchar(100), gender char(1), birth_date date,
    occupation nvarchar(50), monthly_income decimal(18, 0), city nvarchar(50), province nvarchar(50),
    created_at datetime2(0), updated_at datetime2(0)
);
CREATE TABLE stg.loan (
    loan_id varchar(12), customer_id varchar(12), branch_id varchar(10), product_id varchar(10),
    application_date date, disbursement_date date, principal_amount decimal(18, 0),
    interest_rate_flat decimal(5, 4), tenor_months int, installment_amount decimal(18, 0),
    created_at datetime2(0), updated_at datetime2(0)
);
-- Payment rows that passed type conversion in SSIS.
CREATE TABLE stg.payment (
    payment_id      varchar(20)    NOT NULL,
    loan_id         varchar(12)    NOT NULL,
    installment_no  int            NOT NULL,
    payment_date    date           NOT NULL,
    amount          decimal(18, 0) NOT NULL,
    channel         nvarchar(30)   NULL,
    source_file     nvarchar(260)  NOT NULL,
    loaded_at       datetime2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

--------------------------------------------------------------------- dimensions
CREATE TABLE dw.dim_date (
    date_key        int          NOT NULL PRIMARY KEY,  -- yyyymmdd
    full_date       date         NOT NULL UNIQUE,
    year            smallint     NOT NULL,
    quarter         tinyint      NOT NULL,
    month           tinyint      NOT NULL,
    month_name      nvarchar(20) NOT NULL,
    year_month      char(7)      NOT NULL,              -- 2025-12
    day_of_month    tinyint      NOT NULL,
    day_of_week     tinyint      NOT NULL,              -- 1 = Senin
    day_name        nvarchar(10) NOT NULL,
    is_weekend      bit          NOT NULL,
    is_month_end    bit          NOT NULL
);

CREATE TABLE dw.dim_branch (
    branch_key   int IDENTITY(1, 1) PRIMARY KEY,
    branch_id    varchar(10)   NOT NULL UNIQUE,
    branch_name  nvarchar(100) NOT NULL,
    city         nvarchar(50)  NOT NULL,
    province     nvarchar(50)  NOT NULL,
    region       nvarchar(50)  NOT NULL,
    opened_date  date          NULL
);

CREATE TABLE dw.dim_product (
    product_key         int IDENTITY(1, 1) PRIMARY KEY,
    product_id          varchar(10)   NOT NULL UNIQUE,
    product_name        nvarchar(100) NOT NULL,
    category            nvarchar(50)  NOT NULL,
    interest_rate_flat  decimal(5, 4) NULL
);

-- SCD Type 2: a new row whenever occupation, income, or address changes.
CREATE TABLE dw.dim_customer (
    customer_key    int IDENTITY(1, 1) PRIMARY KEY,
    customer_id     varchar(12)    NOT NULL,
    full_name       nvarchar(100)  NOT NULL,
    gender          char(1)        NOT NULL,
    birth_date      date           NULL,
    occupation      nvarchar(50)   NOT NULL,
    monthly_income  decimal(18, 0) NULL,
    income_band     nvarchar(20)   NOT NULL,
    city            nvarchar(50)   NOT NULL,
    province        nvarchar(50)   NOT NULL,
    valid_from      date           NOT NULL,
    valid_to        date           NOT NULL,
    is_current      bit            NOT NULL,
    row_hash        varbinary(32)  NULL
);
CREATE UNIQUE INDEX ux_dim_customer_current ON dw.dim_customer (customer_id) WHERE is_current = 1;
CREATE INDEX ix_dim_customer_lookup ON dw.dim_customer (customer_id, valid_from, valid_to) INCLUDE (customer_key);
GO

-- Unknown members, so a fact row with a missing reference still has a valid key.
SET IDENTITY_INSERT dw.dim_branch ON;
INSERT INTO dw.dim_branch (branch_key, branch_id, branch_name, city, province, region)
VALUES (-1, 'UNKNOWN', N'Unknown', N'Unknown', N'Unknown', N'Unknown');
SET IDENTITY_INSERT dw.dim_branch OFF;

SET IDENTITY_INSERT dw.dim_product ON;
INSERT INTO dw.dim_product (product_key, product_id, product_name, category)
VALUES (-1, 'UNKNOWN', N'Unknown', N'Unknown');
SET IDENTITY_INSERT dw.dim_product OFF;

SET IDENTITY_INSERT dw.dim_customer ON;
INSERT INTO dw.dim_customer (customer_key, customer_id, full_name, gender, occupation, income_band,
                             city, province, valid_from, valid_to, is_current)
VALUES (-1, 'UNKNOWN', N'Unknown', 'U', N'Unknown', N'Unknown', N'Unknown', N'Unknown',
        '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dw.dim_customer OFF;
GO

-------------------------------------------------------------------------- facts
-- One row per loan.
CREATE TABLE dw.fact_loan (
    loan_key                int IDENTITY(1, 1) PRIMARY KEY,
    loan_id                 varchar(12)    NOT NULL UNIQUE,
    customer_key            int            NOT NULL REFERENCES dw.dim_customer (customer_key),
    branch_key              int            NOT NULL REFERENCES dw.dim_branch (branch_key),
    product_key             int            NOT NULL REFERENCES dw.dim_product (product_key),
    application_date_key    int            NOT NULL REFERENCES dw.dim_date (date_key),
    disbursement_date_key   int            NOT NULL REFERENCES dw.dim_date (date_key),
    maturity_date_key       int            NOT NULL REFERENCES dw.dim_date (date_key),
    disbursement_date       date           NOT NULL,
    tenor_months            int            NOT NULL,
    interest_rate_flat      decimal(5, 4)  NOT NULL,
    principal_amount        decimal(18, 0) NOT NULL,
    interest_amount         decimal(18, 0) NOT NULL,
    installment_amount      decimal(18, 0) NOT NULL
);

-- One row per payment received.
CREATE TABLE dw.fact_payment (
    payment_key       bigint IDENTITY(1, 1) PRIMARY KEY,
    payment_id        varchar(20)    NOT NULL UNIQUE,
    loan_key          int            NOT NULL REFERENCES dw.fact_loan (loan_key),
    customer_key      int            NOT NULL REFERENCES dw.dim_customer (customer_key),
    branch_key        int            NOT NULL REFERENCES dw.dim_branch (branch_key),
    product_key       int            NOT NULL REFERENCES dw.dim_product (product_key),
    payment_date_key  int            NOT NULL REFERENCES dw.dim_date (date_key),
    due_date_key      int            NOT NULL REFERENCES dw.dim_date (date_key),
    installment_no    int            NOT NULL,
    amount            decimal(18, 0) NOT NULL,
    days_late         int            NOT NULL,
    channel           nvarchar(30)   NULL,
    source_file       nvarchar(260)  NOT NULL,
    batch_id          int            NULL
);
CREATE INDEX ix_fact_payment_loan ON dw.fact_payment (loan_key, payment_date_key) INCLUDE (installment_no);

-- One row per active loan per month end: outstanding balance and OJK collectibility.
CREATE TABLE dw.fact_loan_monthly_snapshot (
    snapshot_date_key      int            NOT NULL REFERENCES dw.dim_date (date_key),
    loan_key               int            NOT NULL REFERENCES dw.fact_loan (loan_key),
    customer_key           int            NOT NULL,
    branch_key             int            NOT NULL,
    product_key            int            NOT NULL,
    installments_paid      int            NOT NULL,
    outstanding_principal  decimal(18, 0) NOT NULL,
    days_past_due          int            NOT NULL,
    collectibility         tinyint        NOT NULL,  -- 1 Lancar ... 5 Macet
    collectibility_label   nvarchar(30)   NOT NULL,
    is_npl                 bit            NOT NULL,  -- collectibility 3, 4, or 5
    CONSTRAINT pk_fact_loan_monthly_snapshot PRIMARY KEY (snapshot_date_key, loan_key)
);
GO
