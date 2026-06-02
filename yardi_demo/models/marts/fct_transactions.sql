{{
  config(
    materialized='table',
    schema='marts'
  )
}}

{#-
  fct_transactions.sql
  Business-ready transaction fact table:
    - Filters out void transactions (is_void = true)
    - Joins dimension attributes from property, tenant, unit, GL account,
      charge code, and vendor -- replacing the denormalized columns that
      were dropped in staging
    - Adds fiscal year, month, and quarter derived from transaction_date
    - Adds days_to_post latency metric
    - Coalesces vendor_id nulls to -1 for clean joins
-#}

with transactions as (

    select * from {{ ref('stg_transactions') }}
    where not is_void

),

properties as (

    select
        hmy     as property_id,
        scode   as property_code,
        sname   as property_name,
        scity   as property_city,
        sstate  as property_state,
        sregion as property_region,
        sfund   as property_fund
    from {{ source('yardi', 'PROPERTY') }}

),

tenants as (

    select
        hmy        as tenant_id,
        sfullname  as tenant_name,
        istatus    as tenant_status_code,
        mbalance   as tenant_balance
    from {{ source('yardi', 'TENANT') }}

),

units as (

    select
        hmy        as unit_id,
        scode      as unit_code,
        sunittype  as unit_type,
        isqft      as unit_sqft,
        ibedrooms  as unit_bedrooms
    from {{ source('yardi', 'UNIT') }}

),

gl_accounts as (

    select
        hmy    as gl_account_id,
        scode  as gl_account_code,
        sdesc  as gl_account_name,
        stype  as gl_account_type,
        ssubtype as gl_account_subtype
    from {{ source('yardi', 'GLACCT') }}

),

charge_codes as (

    select
        hmy       as charge_code_id,
        scode     as charge_code,
        sdesc     as charge_description,
        scategory as charge_category
    from {{ source('yardi', 'CHARGE') }}

),

vendors as (

    select
        hmy       as vendor_id,
        sname     as vendor_name,
        scategory as vendor_category
    from {{ source('yardi', 'VENDOR') }}

),

final as (

    select
        -- === Transaction Grain ===
        t.transaction_id,
        t.transaction_code,
        t.transaction_type_code,
        t.transaction_type,
        t.transaction_description,

        -- === Dates ===
        t.transaction_date,
        t.posted_date,
        t.effective_date,
        t.fiscal_period,

        -- Derived date parts
        extract(year from t.transaction_date)       as transaction_year,
        extract(month from t.transaction_date)      as transaction_month,
        extract(quarter from t.transaction_date)    as transaction_quarter,

        -- Posting latency
        datediff('day', t.transaction_date, t.posted_date) as days_to_post,

        -- === Monetary Amounts ===
        t.amount,
        t.tax_amount,
        t.total_amount,
        t.net_amount,
        t.running_balance,
        t.is_credit,

        -- === Status ===
        t.status_code,
        t.status_description,

        -- === Payment Details ===
        t.check_number,
        t.reference_number,
        t.bank_account_masked,
        t.notes,

        -- === Property Dimension ===
        t.property_id,
        p.property_code,
        p.property_name,
        p.property_city,
        p.property_state,
        p.property_region,
        p.property_fund,

        -- === Tenant Dimension ===
        t.tenant_id,
        tn.tenant_name,

        -- === Unit Dimension ===
        t.unit_id,
        u.unit_code,
        u.unit_type,

        -- === GL Account Dimension ===
        t.gl_account_id,
        g.gl_account_code,
        g.gl_account_name,
        g.gl_account_type,
        g.gl_account_subtype,

        -- === Charge Code Dimension ===
        t.charge_code_id,
        cc.charge_code,
        cc.charge_description,
        cc.charge_category,

        -- === Vendor Dimension (nullable) ===
        t.vendor_id,
        v.vendor_name,
        v.vendor_category,

        -- === Audit ===
        t.created_at,
        t.created_by

    from transactions t

    left join properties p
        on t.property_id = p.property_id

    left join tenants tn
        on t.tenant_id = tn.tenant_id

    left join units u
        on t.unit_id = u.unit_id

    left join gl_accounts g
        on t.gl_account_id = g.gl_account_id

    left join charge_codes cc
        on t.charge_code_id = cc.charge_code_id

    left join vendors v
        on t.vendor_id = v.vendor_id

)

select * from final
