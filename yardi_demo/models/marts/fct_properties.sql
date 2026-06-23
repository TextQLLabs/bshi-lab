{{
    config(
        materialized = 'table',
        schema       = 'marts'
    )
}}

{#-
    fct_properties
    ==============
    Analytics-ready property fact/dimension at one-row-per-property grain.
    Built on int_yardi__properties (ephemeral) which resolves region
    conformance and all derived metrics.

    Design decisions:
      - Materialized as a full-refresh TABLE.  PROPERTY is small (~20 rows)
        and slowly changing; full refresh is simpler and cheaper than
        incremental here.
      - Surrogate key (property_sk) via dbt_utils for downstream joins /
        snapshot compatibility.
      - Conformed `region` (derived from state) is the reporting default;
        raw region signals are retained for audit/lineage.
      - All properties are kept (active, inactive, disposed).  Filter with
        is_active / ownership_status for clean current-portfolio reporting.
-#}

with properties as (

    select * from {{ ref('int_yardi__properties') }}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['property_id']) }} as property_sk,

        -- ===== Natural / business keys =====
        property_id,
        property_code,
        legacy_property_id,

        -- ===== Descriptive =====
        property_name,
        property_type,
        fund,
        total_units,

        -- ===== Address =====
        address_line_1,
        address_line_2,
        city,
        state_code,
        zip_code,
        county,

        -- ===== Region (conformed + audit) =====
        region,
        region_raw,
        legacy_region_code,
        region_signals_conflict,

        -- ===== Management & ownership =====
        manager_name,
        manager_email,
        owner_name,
        owner_tax_id_last4,
        owner_id,

        -- ===== Dates =====
        acquired_date,
        disposed_date,

        -- ===== Lifecycle =====
        ownership_status,
        hold_period_years,

        -- ===== Measures =====
        market_value,
        purchase_price,
        value_appreciation,
        value_appreciation_pct,
        market_value_per_unit,

        -- ===== Flags =====
        is_active,
        is_tax_exempt,

        -- ===== Free text =====
        notes,

        -- ===== Audit & DQ =====
        created_at,
        modified_at,
        modified_by,
        _stg_acquired_date_parse_failed,
        _stg_disposed_date_parse_failed,
        _stg_county_missing,
        current_timestamp()                          as _dbt_loaded_at

    from properties

)

select * from final
