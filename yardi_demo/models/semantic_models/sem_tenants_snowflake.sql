-- =============================================================================
-- Snowflake Semantic View: SEM_TENANTS
-- =============================================================================
-- Purpose : Governed metric layer over the Yardi TENANT dimension for the
--           real-estate portfolio use case. Exposes tenant facts, dimensions,
--           and portfolio-management metrics (delinquency, AR exposure,
--           retention, credit quality) to Cortex Analyst / BI.
--
-- Grain   : one row per tenant (TENANT.HMY), 189 tenants in current extract.
--
-- Backing : Preferred  -> YARDI.MARTS.DIM_TENANTS  (once `dbt run` has
--                         materialized the tenant medallion chain).
--           Bootstrap  -> an inline clean of YARDI.RAW.TENANT (below), so the
--                         view is usable BEFORE the marts are built. The inline
--                         logic mirrors stg_yardi__tenants + int_yardi__tenant_details
--                         (ISTATUS decode, parse_mixed_date on DTBIRTH, century
--                         correction, tenure/credit/balance derivations).
--
-- To switch to the mart once built: replace the TABLES section base table with
--   tenants AS YARDI.MARTS.DIM_TENANTS PRIMARY KEY (tenant_id)
-- and delete the bootstrap view definition. Column names already align.
-- =============================================================================

-- ---------- Bootstrap cleansing view (drop once DIM_TENANTS is materialized) --
CREATE OR REPLACE VIEW YARDI.MARTS.V_TENANT_SEMANTIC_BASE AS
WITH parsed AS (
    SELECT
        t.HMY                                             AS tenant_id,
        t.SCODE                                           AS tenant_code,
        t.SFULLNAME                                       AS full_name,
        t.HPROPERTY                                       AS property_id,
        NULLIF(t.HUNIT, 0)                                AS unit_id,
        NULLIF(t.HLEASE, 0)                               AS lease_id,
        CASE t.ISTATUS WHEN 0 THEN 'current'
                       WHEN 1 THEN 'former'
                       ELSE 'unknown_' || t.ISTATUS::VARCHAR END AS tenant_status,
        (t.BACTIVE = 1)                                   AS is_active,
        t.MBALANCE                                        AS account_balance,
        t.MDEPOSIT                                        AS deposit,
        t.MLASTPAYMENT                                    AS last_payment_amount,
        t.DTLASTPAYMENT                                   AS last_payment_date,
        t.ICREDITSCORE                                    AS credit_score,
        t.SLEASETYPE                                      AS lease_type,
        t.DTMOVEIN                                        AS move_in_date,
        t.DTMOVEOUT                                       AS move_out_date,
        -- DTBIRTH: mixed-format TEXT -> DATE (5 formats)
        COALESCE(
            TRY_TO_DATE(t.DTBIRTH, 'YYYY-MM-DD'),
            TRY_TO_DATE(t.DTBIRTH, 'MM/DD/YYYY'),
            TRY_TO_DATE(t.DTBIRTH, 'MM/DD/YY'),
            TRY_TO_DATE(t.DTBIRTH, 'DD-Mon-YYYY'),
            TRY_TO_DATE(t.DTBIRTH, 'MM-DD-YYYY')
        )                                                 AS birth_date_raw
    FROM YARDI.RAW.TENANT t
),
derived AS (
    SELECT
        p.*,
        -- 2-digit-year century correction (<=25 -> 2000s else 1900s)
        CASE
            WHEN birth_date_raw IS NULL THEN NULL
            WHEN YEAR(birth_date_raw) < 100 THEN
                DATEADD('year', CASE WHEN YEAR(birth_date_raw) <= 25 THEN 2000 ELSE 1900 END, birth_date_raw)
            ELSE birth_date_raw
        END                                               AS birth_date
    FROM parsed p
)
SELECT
    d.tenant_id,
    d.tenant_code,
    d.full_name,
    d.property_id,
    d.unit_id,
    d.lease_id,
    d.tenant_status,
    d.is_active,
    (d.tenant_status = 'current')                         AS is_current,
    (d.tenant_status = 'former')                          AS is_former,
    d.account_balance,
    d.deposit,
    d.last_payment_amount,
    d.last_payment_date,
    DATEDIFF('day', d.last_payment_date, CURRENT_DATE())  AS days_since_last_payment,
    (d.account_balance > 0)                               AS is_delinquent,
    (d.account_balance < 0)                               AS is_in_credit,
    CASE WHEN d.account_balance > 0 THEN 'delinquent'
         WHEN d.account_balance < 0 THEN 'credit'
         ELSE 'clear' END                                 AS balance_status,
    d.credit_score,
    CASE WHEN d.credit_score IS NULL THEN 'unknown'
         WHEN d.credit_score < 580 THEN 'poor'
         WHEN d.credit_score < 670 THEN 'fair'
         WHEN d.credit_score < 740 THEN 'good'
         ELSE 'excellent' END                             AS credit_band,
    d.lease_type,
    d.move_in_date,
    d.move_out_date,
    DATEDIFF('month', d.move_in_date, COALESCE(d.move_out_date, CURRENT_DATE())) AS tenure_months,
    d.birth_date,
    CASE WHEN d.birth_date IS NOT NULL
          AND FLOOR(DATEDIFF('day', d.birth_date, CURRENT_DATE()) / 365.25) BETWEEN 18 AND 100
         THEN FLOOR(DATEDIFF('day', d.birth_date, CURRENT_DATE()) / 365.25) END AS age_years,
    -- property attributes for dimensional slicing
    pr.SNAME                                              AS property_name,
    pr.SCITY                                              AS property_city,
    pr.SSTATE                                             AS property_state,
    pr.SREGION                                            AS property_region,
    pr.SFUND                                              AS property_fund
FROM derived d
LEFT JOIN YARDI.RAW.PROPERTY pr ON d.property_id = pr.HMY;


-- ---------- The semantic view --------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW YARDI.MARTS.SEM_TENANTS
    TABLES (
        tenants AS YARDI.MARTS.V_TENANT_SEMANTIC_BASE
            PRIMARY KEY (tenant_id)
            WITH SYNONYMS ('tenant', 'residents', 'renters')
            COMMENT = 'One row per Yardi tenant with property context and derived economics.'
    )

    FACTS (
        tenants.account_balance AS account_balance
            COMMENT = 'Current AR balance for the tenant; negative = credit.',
        tenants.deposit AS deposit
            COMMENT = 'Security deposit held.',
        tenants.credit_score AS credit_score
            COMMENT = 'Application credit score (300-850).',
        tenants.tenure_months AS tenure_months
            COMMENT = 'Months from move-in to move-out (or today if in place).',
        tenants.last_payment_amount AS last_payment_amount
            COMMENT = 'Amount of most recent payment.',
        tenants.days_since_last_payment AS days_since_last_payment
            COMMENT = 'Days between last payment and today.',
        tenants.age_years AS age_years
            COMMENT = 'Tenant age in years (18-100 guard applied).'
    )

    DIMENSIONS (
        tenants.tenant_id       AS tenant_id       WITH SYNONYMS = ('tenant key','tenant number'),
        tenants.tenant_code     AS tenant_code,
        tenants.full_name       AS full_name       WITH SYNONYMS = ('tenant name','resident name'),
        tenants.tenant_status   AS tenant_status   WITH SYNONYMS = ('status','current or former')
            COMMENT = 'current or former.',
        tenants.is_current      AS is_current,
        tenants.is_former       AS is_former,
        tenants.is_delinquent   AS is_delinquent,
        tenants.balance_status  AS balance_status  WITH SYNONYMS = ('delinquent / credit / clear')
            COMMENT = 'delinquent (owes), credit (overpaid), or clear.',
        tenants.credit_band     AS credit_band     WITH SYNONYMS = ('credit quality')
            COMMENT = 'poor / fair / good / excellent / unknown.',
        tenants.lease_type      AS lease_type      WITH SYNONYMS = ('FIXED or MTM'),
        tenants.move_in_date    AS move_in_date,
        tenants.move_out_date   AS move_out_date,
        tenants.property_id     AS property_id,
        tenants.property_name   AS property_name   WITH SYNONYMS = ('property','building','asset'),
        tenants.property_city   AS property_city,
        tenants.property_state  AS property_state,
        tenants.property_region AS property_region WITH SYNONYMS = ('region'),
        tenants.property_fund   AS property_fund   WITH SYNONYMS = ('fund')
    )

    METRICS (
        -- Population
        tenants.tenant_count AS COUNT(tenants.tenant_id)
            WITH SYNONYMS = ('number of tenants','tenant headcount','resident count')
            COMMENT = 'Number of tenants.',
        tenants.current_tenant_count AS COUNT_IF(tenants.is_current)
            COMMENT = 'Tenants currently in place.',
        tenants.former_tenant_count AS COUNT_IF(tenants.is_former)
            COMMENT = 'Tenants who have moved out.',

        -- Delinquency / AR
        tenants.delinquent_tenant_count AS COUNT_IF(tenants.is_delinquent)
            WITH SYNONYMS = ('tenants in arrears','past-due tenants')
            COMMENT = 'Tenants with a positive AR balance.',
        tenants.delinquency_rate AS COUNT_IF(tenants.is_delinquent) / NULLIF(COUNT(tenants.tenant_id), 0)
            WITH SYNONYMS = ('percent delinquent','arrears rate')
            COMMENT = 'Share of tenants with a positive balance.',
        tenants.total_ar_balance AS SUM(tenants.account_balance)
            WITH SYNONYMS = ('accounts receivable','outstanding balance','total balance owed')
            COMMENT = 'Sum of tenant AR balances (net of credits).',
        tenants.total_delinquent_balance AS SUM(CASE WHEN tenants.is_delinquent THEN tenants.account_balance ELSE 0 END)
            COMMENT = 'Sum of balances for delinquent tenants only.',
        tenants.avg_balance AS AVG(tenants.account_balance)
            COMMENT = 'Average AR balance per tenant.',

        -- Deposits / exposure
        tenants.total_deposits_held AS SUM(tenants.deposit)
            WITH SYNONYMS = ('security deposits','deposit liability')
            COMMENT = 'Total security deposits held.',

        -- Credit quality
        tenants.avg_credit_score AS AVG(tenants.credit_score)
            WITH SYNONYMS = ('mean credit score')
            COMMENT = 'Average tenant credit score.',

        -- Retention / tenure
        tenants.avg_tenure_months AS AVG(tenants.tenure_months)
            WITH SYNONYMS = ('average tenancy length','mean tenure')
            COMMENT = 'Average months of tenancy.'
    )

    COMMENT = 'Governed tenant metric layer for Yardi real-estate portfolio reporting (delinquency, AR exposure, retention, credit quality). Grain: one row per tenant.';
