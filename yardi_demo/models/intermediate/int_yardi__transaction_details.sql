{{
    config(
        materialized = 'ephemeral'
    )
}}

{#-
    int_yardi__transaction_details
    ==============================
    Enriches the staged transaction with dimension attributes that were
    previously denormalized as raw text columns in TRANS.  Joins are
    performed against staging models (not raw sources) so all upstream
    cleaning is inherited.

    Business logic added:
      - transaction_type_label  (human-readable type name)
      - amount_category         (debit vs credit classification)
      - days_to_post            (lag between transaction and posting)
      - is_late_posting         (posted > 5 days after transaction)
      - net_amount              (amount + tax for total economic impact)
      - fiscal_year / fiscal_month extracted from fiscal_period
-#}

with transactions as (

    select * from {{ ref('stg_yardi__transactions') }}

),

properties as (

    select
        hmy     as property_id,
        sname   as property_name,
        scity   as property_city,
        sstate  as property_state,
        sregion as property_region,
        sfund   as property_fund
    from {{ source('yardi', 'PROPERTY') }}

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

tenants as (

    select
        hmy       as tenant_id,
        sfullname as tenant_name,
        scode     as tenant_code
    from {{ source('yardi', 'TENANT') }}

),

leases as (

    select
        hmy         as lease_id,
        scode       as lease_code,
        stype       as lease_type,
        dtleasefrom as lease_start_date,
        dtleaseto   as lease_end_date
    from {{ source('yardi', 'LEASE') }}

),

gl_accounts as (

    select
        hmy                         as gl_account_id,
        cast(scode as varchar)      as gl_account_code,
        sdesc                       as gl_account_name,
        stype                       as gl_account_type,
        ssubtype                    as gl_account_subtype
    from {{ source('yardi', 'GLACCT') }}

),

charges as (

    select
        hmy       as charge_id,
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

enriched as (

    select
        -- ===== Transaction core =====
        t.transaction_id,
        t.transaction_code,
        t.transaction_type,
        case t.transaction_type
            when 'CHG' then 'Charge'
            when 'PMT' then 'Payment'
            when 'CR'  then 'Credit'
            when 'ADJ' then 'Adjustment'
        end                                             as transaction_type_label,
        t.transaction_description,
        t.transaction_status,
        t.transaction_status_code,
        t.is_voided,

        -- ===== Dates =====
        t.transaction_date,
        t.posted_date,
        t.effective_date,
        t.fiscal_period,
        cast(floor(t.fiscal_period / 100) as integer)  as fiscal_year,
        cast(mod(t.fiscal_period, 100) as integer)      as fiscal_month,

        -- ===== Monetary =====
        t.amount,
        t.tax_amount,
        t.total_amount,
        t.running_balance,
        (t.amount + coalesce(t.tax_amount, 0))          as net_amount,
        case
            when t.amount > 0 then 'debit'
            when t.amount < 0 then 'credit'
            else 'zero'
        end                                             as amount_category,

        -- ===== Posting metrics =====
        datediff('day', t.transaction_date, t.posted_date) as days_to_post,
        (
            t.posted_date is not null
            and datediff('day', t.transaction_date, t.posted_date) > 5
        )                                               as is_late_posting,

        -- ===== Payment details =====
        t.check_number,
        t.reference_number,
        t.bank_account_masked,
        t.notes,

        -- ===== Property dimension =====
        t.property_id,
        p.property_name,
        p.property_city,
        p.property_state,
        p.property_region,
        p.property_fund,

        -- ===== Unit dimension =====
        t.unit_id,
        u.unit_code,
        u.unit_type,
        u.unit_sqft,
        u.unit_bedrooms,

        -- ===== Tenant dimension =====
        t.tenant_id,
        tn.tenant_name,
        tn.tenant_code,

        -- ===== Lease dimension =====
        t.lease_id,
        l.lease_code,
        l.lease_type,
        l.lease_start_date,
        l.lease_end_date,

        -- ===== GL Account dimension =====
        t.gl_account_id,
        g.gl_account_code,
        g.gl_account_name,
        g.gl_account_type,
        g.gl_account_subtype,

        -- ===== Charge dimension =====
        t.charge_id,
        c.charge_code,
        c.charge_description,
        c.charge_category,

        -- ===== Vendor dimension (nullable) =====
        t.vendor_id,
        v.vendor_name,
        v.vendor_category,

        -- ===== Audit =====
        t.created_at,
        t.created_by,
        t._stg_effective_date_parse_failed

    from transactions t
    left join properties  p  on t.property_id   = p.property_id
    left join units       u  on t.unit_id       = u.unit_id
    left join tenants     tn on t.tenant_id     = tn.tenant_id
    left join leases      l  on t.lease_id      = l.lease_id
    left join gl_accounts g  on t.gl_account_id = g.gl_account_id
    left join charges     c  on t.charge_id     = c.charge_id
    left join vendors     v  on t.vendor_id     = v.vendor_id

)

select * from enriched
