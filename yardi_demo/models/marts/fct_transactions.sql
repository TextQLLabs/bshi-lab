{{
    config(
        materialized         = 'incremental',
        unique_key           = 'transaction_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    fct_transactions
    ================
    Analytics-ready transaction fact table at the individual-transaction
    grain.  Built on top of int_yardi__transaction_details (ephemeral)
    which resolves all dimension joins.

    Design decisions:
      - Incremental merge on transaction_id using created_at as the
        watermark.  This handles both new inserts and late-arriving
        updates (e.g. a transaction that gets voided after initial load).
      - Voided transactions are INCLUDED with is_voided = true so that
        downstream consumers can choose to filter or audit them.
      - Reversed transactions (status = 'reversed') are similarly kept.
      - Dimension FKs are retained alongside the denormalized attributes
        so the table works both as a wide fact and as a joinable fact.
      - Surrogate key (transaction_sk) generated via dbt_utils for
        downstream SCD or snapshot compatibility.
-#}

with transaction_details as (

    select * from {{ ref('int_yardi__transaction_details') }}

    {% if is_incremental() %}
    where created_at > (select max(created_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key([
            'transaction_id'
        ]) }}                                       as transaction_sk,

        -- ===== Natural key =====
        transaction_id,
        transaction_code,

        -- ===== Transaction classification =====
        transaction_type,
        transaction_type_label,
        transaction_description,
        transaction_status,
        is_voided,
        amount_category,

        -- ===== Dates (role-playing) =====
        transaction_date,
        posted_date,
        effective_date,
        fiscal_period,
        fiscal_year,
        fiscal_month,

        -- ===== Measures =====
        amount,
        tax_amount,
        total_amount,
        net_amount,
        running_balance,

        -- ===== Posting quality =====
        days_to_post,
        is_late_posting,

        -- ===== Payment details =====
        check_number,
        reference_number,
        bank_account_masked,
        notes,

        -- ===== Property dimension =====
        property_id,
        property_name,
        property_city,
        property_state,
        property_region,
        property_fund,

        -- ===== Unit dimension =====
        unit_id,
        unit_code,
        unit_type,
        unit_sqft,

        -- ===== Tenant dimension =====
        tenant_id,
        tenant_name,
        tenant_code,

        -- ===== Lease dimension =====
        lease_id,
        lease_code,
        lease_type,

        -- ===== GL Account dimension =====
        gl_account_id,
        gl_account_code,
        gl_account_name,
        gl_account_type,
        gl_account_subtype,

        -- ===== Charge dimension =====
        charge_id,
        charge_code,
        charge_description,
        charge_category,

        -- ===== Vendor dimension (nullable) =====
        vendor_id,
        vendor_name,
        vendor_category,

        -- ===== Audit =====
        created_at,
        created_by,
        _stg_effective_date_parse_failed,
        current_timestamp()                         as _dbt_loaded_at

    from transaction_details

)

select * from final
