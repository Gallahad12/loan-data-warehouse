-- LoanCore: the source OLTP database of a fictional multifinance company.
-- Run this once, then load source/loancore_seed.sql.
IF DB_ID('LoanCore') IS NULL
    CREATE DATABASE LoanCore;
GO
USE LoanCore;
GO

DROP TABLE IF EXISTS dbo.loan;
DROP TABLE IF EXISTS dbo.customer;
DROP TABLE IF EXISTS dbo.product;
DROP TABLE IF EXISTS dbo.branch;
GO

CREATE TABLE dbo.branch (
    branch_id    varchar(10)   NOT NULL PRIMARY KEY,
    branch_name  nvarchar(100) NOT NULL,
    city         nvarchar(50)  NOT NULL,
    province     nvarchar(50)  NOT NULL,
    region       nvarchar(50)  NOT NULL,
    opened_date  date          NOT NULL,
    updated_at   datetime2(0)  NOT NULL
);

CREATE TABLE dbo.product (
    product_id          varchar(10)   NOT NULL PRIMARY KEY,
    product_name        nvarchar(100) NOT NULL,
    category            nvarchar(50)  NOT NULL,
    interest_rate_flat  decimal(5, 4) NOT NULL,  -- annual flat rate, 0.2000 = 20%
    updated_at          datetime2(0)  NOT NULL
);

CREATE TABLE dbo.customer (
    customer_id     varchar(12)    NOT NULL PRIMARY KEY,
    full_name       nvarchar(100)  NOT NULL,
    gender          char(1)        NOT NULL,
    birth_date      date           NOT NULL,
    occupation      nvarchar(50)   NOT NULL,
    monthly_income  decimal(18, 0) NOT NULL,
    city            nvarchar(50)   NOT NULL,
    province        nvarchar(50)   NOT NULL,
    created_at      datetime2(0)   NOT NULL,
    updated_at      datetime2(0)   NOT NULL
);

CREATE TABLE dbo.loan (
    loan_id             varchar(12)    NOT NULL PRIMARY KEY,
    customer_id         varchar(12)    NOT NULL REFERENCES dbo.customer (customer_id),
    branch_id           varchar(10)    NOT NULL REFERENCES dbo.branch (branch_id),
    product_id          varchar(10)    NOT NULL REFERENCES dbo.product (product_id),
    application_date    date           NOT NULL,
    disbursement_date   date           NOT NULL,
    principal_amount    decimal(18, 0) NOT NULL,
    interest_rate_flat  decimal(5, 4)  NOT NULL,
    tenor_months        int            NOT NULL,
    installment_amount  decimal(18, 0) NOT NULL,
    created_at          datetime2(0)   NOT NULL,
    updated_at          datetime2(0)   NOT NULL
);

-- The incremental extract filters on updated_at.
CREATE INDEX ix_customer_updated_at ON dbo.customer (updated_at);
CREATE INDEX ix_loan_updated_at ON dbo.loan (updated_at);
GO
