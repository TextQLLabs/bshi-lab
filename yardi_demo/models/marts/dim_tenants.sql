{{
    config(
        materialized         = 'incremental',
        schema               = 'marts',
        unique_key           = 'tenant_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    dim_tenants
    ===========
    Analytics-ready tenant dimension at the one-row-per-tenant grain.  Built
    on int_yardi__tenant_details (ephemeral) which resolves the property /
    unit / lease joins and derived economics.

    Design decisions:
      - Incremental merge on tenant_id using modified_at as the watermark so
        balance / status / credit changes are upserted on each run.
      - All tenant statuses retained (current, former); filter is_current
        = true for active-resident reporting.
      - Surrogate key (tenant_sk) generated via dbt_utils for downstream
        snapshot / SCD compatibility.
      - Derived measures (tenure, balance_status, credit_band, age_years)
        carried through for direct BI consumption.
      - PII kept masked (ssn_last4) and minimal (no raw SSN); contact fields
        pass through for operational use.
-#}

with tenant_details as (

    select * from {{ ref('int_yardi__tenant_details') }}

    {% if is_incremental() %}
    where modified_at > (select max(modified_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['tenant_id']) }}  as tenant_sk,

        -- ===== Natural key =====
        tenant_id,
        tenant_code,

        -- ===== Name & contact =====
        first_name,
        last_name,
        full_name,
        phone,
        email,
        emergency_contact_name,
        emergency_contact_phone,
        ssn_last4,

        -- ===== Demographics =====
        birth_date,
        age_years,

        -- ===== Status =====
        tenant_status,
        tenant_status_code,
        is_active,
        is_current,
        is_former,

        -- ===== Tenancy & tenure =====
        move_in_date,
        move_out_date,
        tenure_days,
        tenure_months,

        -- ===== Financials =====
        account_balance,
        deposit,
        last_payment_amount,
        last_payment_date,
        days_since_last_payment,
        is_delinquent,
        is_in_credit,
        balance_status,

        -- ===== Credit =====
        credit_score,
        credit_band,

        -- ===== Lease =====
        lease_id,
        lease_type,
        lease_term_type,
        lease_from_date,
        lease_to_date,
        lease_rent,

        -- ===== Unit dimension =====
        unit_id,
        unit_code,
        unit_type,
        square_feet,

        -- ===== Property dimension =====
        property_id,
        property_name,
        property_city,
        property_state,
        property_region,
        property_fund,

        -- ===== Audit / DQ =====
        created_at,
        modified_at,
        _stg_birth_date_parse_failed,
        _birth_century_imputed,
        current_timestamp()                                   as _dbt_loaded_at

    from tenant_details

)

select * from final
