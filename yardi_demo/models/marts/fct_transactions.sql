{{
    config(
        materialized    = 'incremental',
        unique_key      = 'transaction_id',
        incremental_strategy = 'merge',
        cluster_by      = ['transaction_date']
    )
}}

/*
    Mart: fct_transactions

    Grain: one row per financial transaction from Yardi RAW.TRANS.

    Voided and non-posted rows are INCLUDED by design, so the fact can serve
    both financial reporting and audit. For clean financial reporting filter:

        where is_voided = false
          and transaction_status = 'posted'

    Measure additivity:
      - amount, tax_amount, total_amount, net_amount : fully additive
      - running_balance : SEMI-additive point-in-time balance. Never SUM it;
        take the value at the latest transaction_date per tenant.
*/

with transactions as (

    select * from {{ ref('int_yardi__transaction_details') }}

    {% if is_incremental() %}
        where created_at > (select coalesce(max(created_at), '1900-01-01')
                            from {{ this }})
    {% endif %}

)

select
    {{ dbt_utils.generate_surrogate_key(['transaction_id']) }} as transaction_sk,
    transaction_id,

    -- foreign keys
    property_id,
    unit_id,
    tenant_id,
    lease_id,
    batch_id,
    gl_account_id,
    charge_id,
    vendor_id,

    -- denormalized dimension attributes for direct BI consumption
    property_name,
    region,
    fund,
    unit_code,
    tenant_name,
    lease_code,
    lease_type,
    gl_account_code,
    gl_account_name,
    gl_account_type,
    charge_code,
    charge_name,
    charge_category,
    vendor_name,

    -- degenerate dimensions
    transaction_code,
    transaction_type,
    transaction_type_label,
    transaction_class,
    transaction_description,
    reference,
    check_number,
    bank_account,
    amount_category,

    -- status
    transaction_status_code,
    transaction_status,
    is_voided,

    -- dates
    transaction_date,
    transaction_month,
    posted_date,
    effective_date,
    accounting_period,
    fiscal_year,
    fiscal_month,
    days_to_post,
    is_late_posting,

    -- measures (additive)
    amount,
    tax_amount,
    total_amount,
    net_amount,

    -- measure (semi-additive -- never SUM)
    running_balance,

    -- data quality
    _stg_effective_date_parse_failed,

    -- audit
    created_by,
    created_at,
    current_timestamp() as _dbt_loaded_at

from transactions
