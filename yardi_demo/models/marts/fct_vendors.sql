{{
    config(
        materialized = 'table',
        schema       = 'marts'
    )
}}

{#-
    fct_vendors
    ===========
    Analytics-ready vendor fact/dimension at one-row-per-vendor grain.
    Built on int_yardi__vendors (ephemeral) which resolves region
    conformance, category decode, and insurance/1099 business logic.

    Design decisions:
      - Materialized as a full-refresh TABLE.  VENDOR is small (~25 rows)
        and slowly changing; full refresh is simpler and cheaper than
        incremental here (mirrors fct_properties).
      - Surrogate key (vendor_sk) via dbt_utils for downstream joins /
        snapshot compatibility.  fct_transactions.vendor_id joins here.
      - All vendors are kept (active, inactive).  Filter with is_active /
        vendor_status for clean active-vendor reporting.
      - insurance_status / is_insurance_expired surface a compliance view
        (vendors with lapsed or missing certificates of insurance).
-#}

with vendors as (

    select * from {{ ref('int_yardi__vendors') }}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['vendor_id']) }} as vendor_sk,

        -- ===== Natural / business keys =====
        vendor_id,
        vendor_code,
        legacy_vendor_id,

        -- ===== Descriptive =====
        vendor_name,
        category,
        category_raw,

        -- ===== Address =====
        address_line_1,
        address_line_2,
        city,
        state_code,
        zip_code,
        region,

        -- ===== Contact =====
        phone,
        fax,
        email,

        -- ===== Tax / 1099 =====
        tax_id_last4,
        form_1099_type,
        form_1099_amount,
        is_1099_reportable,

        -- ===== Insurance =====
        insurance_policy_number,
        insurance_expiry_date,
        insurance_status,
        is_insurance_expired,

        -- ===== Lifecycle =====
        vendor_status,
        is_active,
        is_preferred,

        -- ===== Measures =====
        ytd_paid,

        -- ===== Free text =====
        notes,

        -- ===== Audit & DQ =====
        created_at,
        modified_at,
        _stg_insurance_expiry_parse_failed,
        _stg_insurance_incomplete,
        current_timestamp()                          as _dbt_loaded_at

    from vendors

)

select * from final
