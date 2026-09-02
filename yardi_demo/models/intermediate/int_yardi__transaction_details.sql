{{
    config(
        materialized = 'ephemeral'
    )
}}

/*
    Intermediate: fully enriched transaction record.

    Joins the staged transaction against its dimension sources and adds
    derived business columns. Ephemeral -- consumed only by fct_transactions.

    Note on joins: the dimension staging models (stg_yardi__properties etc.)
    are not yet implemented in this project, so this model reads the
    dimension attributes directly from source(). Swap these to ref() as each
    staging model lands; the column contract here does not change.
*/

with transactions as (

    select * from {{ ref('stg_yardi__transactions') }}

),

property as (
    select HMY as property_id, SNAME as property_name,
           SREGION as region, SFUND as fund
    from {{ source('yardi', 'PROPERTY') }}
),

unit as (
    select HMY as unit_id, SCODE as unit_code
    from {{ source('yardi', 'UNIT') }}
),

tenant as (
    select HMY as tenant_id, SFULLNAME as tenant_name
    from {{ source('yardi', 'TENANT') }}
),

lease as (
    select HMY as lease_id, SCODE as lease_code, STYPE as lease_type
    from {{ source('yardi', 'LEASE') }}
),

gl_account as (
    select HMY as gl_account_id, SCODE::varchar as gl_account_code,
           SDESC as gl_account_name, STYPE as gl_account_type
    from {{ source('yardi', 'GLACCT') }}
),

charge as (
    select HMY as charge_id, SCODE as charge_code,
           SDESC as charge_name, SCATEGORY as charge_category
    from {{ source('yardi', 'CHARGE') }}
),

vendor as (
    select HMY as vendor_id, SNAME as vendor_name
    from {{ source('yardi', 'VENDOR') }}
),

enriched as (

    select
        t.transaction_id,

        -- foreign keys
        t.property_id, t.unit_id, t.tenant_id, t.lease_id,
        t.batch_id, t.gl_account_id, t.charge_id, t.vendor_id,

        -- resolved dimension attributes (replace denormalized source text)
        p.property_name,
        p.region,
        p.fund,
        u.unit_code,
        te.tenant_name,
        l.lease_code,
        l.lease_type,
        g.gl_account_code,
        g.gl_account_name,
        g.gl_account_type,
        c.charge_code,
        c.charge_name,
        c.charge_category,
        v.vendor_name,

        -- transaction descriptors
        t.transaction_code,
        t.transaction_type,
        case t.transaction_type
            when 'CHG' then 'Charge'
            when 'PMT' then 'Payment'
            when 'CR'  then 'Credit'
            when 'ADJ' then 'Adjustment'
            else 'Unknown'
        end                                     as transaction_type_label,
        case
            when t.transaction_type in ('CHG', 'ADJ') then 'Billing'
            else 'Settlement'
        end                                     as transaction_class,
        t.transaction_description,
        t.reference,
        t.check_number,
        t.bank_account,

        -- status
        t.transaction_status_code,
        t.transaction_status,
        t.is_voided,

        -- dates and fiscal attributes
        t.transaction_date,
        t.posted_date,
        t.effective_date,
        t.accounting_period,
        date_trunc('month', t.transaction_date) as transaction_month,
        year(t.transaction_date)                as fiscal_year,
        month(t.transaction_date)               as fiscal_month,
        datediff('day', t.transaction_date, t.posted_date) as days_to_post,
        coalesce(
            datediff('day', t.transaction_date, t.posted_date) > 5,
            false
        )                                       as is_late_posting,

        -- measures
        t.amount,
        t.tax_amount,
        t.total_amount,
        /*
            net_amount restates the ledger in "billing positive" terms:
            charges and adjustments increase the tenant receivable, payments
            and credits reduce it. The source sign convention is already
            consistent (all 868 CHG and 301 ADJ positive; all 528 PMT and
            303 CR negative), so this is a presentation flip, not a repair.
        */
        case
            when t.transaction_type in ('CHG', 'ADJ') then t.total_amount
            else -1 * t.total_amount
        end                                     as net_amount,
        t.running_balance,

        -- amount banding for distribution analysis
        case
            when abs(t.total_amount) < 500                                then 'under_500'
            when abs(t.total_amount) >= 500  and abs(t.total_amount) < 1000 then '500_to_1k'
            when abs(t.total_amount) >= 1000 and abs(t.total_amount) < 2500 then '1k_to_2.5k'
            when abs(t.total_amount) >= 2500 and abs(t.total_amount) < 5000 then '2.5k_to_5k'
            else '5k_plus'
        end                                     as amount_category,

        -- data quality
        t._stg_effective_date_parse_failed,

        -- audit
        t.created_by,
        t.created_at

    from transactions t
    left join property   p  on t.property_id   = p.property_id
    left join unit       u  on t.unit_id       = u.unit_id
    left join tenant     te on t.tenant_id     = te.tenant_id
    left join lease      l  on t.lease_id      = l.lease_id
    left join gl_account g  on t.gl_account_id = g.gl_account_id
    left join charge     c  on t.charge_id     = c.charge_id
    left join vendor     v  on t.vendor_id     = v.vendor_id

)

select * from enriched
