{{
    config(
        materialized         = 'incremental',
        schema               = 'marts',
        unique_key           = 'property_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    dim_properties
    ==============
    Analytics-ready property dimension at the one-row-per-property grain.
    Built on int_yardi__property_details (ephemeral) which resolves the
    conformed region, valuation metrics and DQ flags.

    Design decisions:
      - Incremental merge on property_id using modified_at as the watermark
        so property attribute changes are upserted on each run.
      - `region` is the conformed (state-derived) region; region_reported is
        retained for audit but should NOT be used for reporting.
      - All properties retained (active and disposed); filter is_active =
        true or is_disposed = false for the live portfolio.
      - Surrogate key (property_sk) via dbt_utils for snapshot / SCD use.
-#}

with property_details as (

    select * from {{ ref('int_yardi__property_details') }}

    {% if is_incremental() %}
    where modified_at > (select max(modified_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['property_id']) }} as property_sk,

        -- ===== Natural key =====
        property_id,
        property_code,

        -- ===== Descriptive attributes =====
        property_name,
        property_type,
        property_type_code,
        property_size_band,

        -- ===== Address =====
        address_line_1,
        address_line_2,
        city,
        state,
        zip_code,
        county,

        -- ===== Region (conformed) & fund =====
        region,
        region_reported,
        legacy_region_code,
        fund,

        -- ===== Ownership =====
        owner_id,
        owner_name,
        owner_tax_id_masked,

        -- ===== Size =====
        reported_total_units,
        actual_unit_count,

        -- ===== Economics =====
        market_value,
        purchase_price,
        value_gain,
        value_gain_pct,
        market_value_per_unit,

        -- ===== Lifecycle =====
        acquired_date,
        disposed_date,
        is_disposed,
        hold_period_years,
        is_active,
        is_tax_exempt,

        -- ===== Audit / DQ =====
        notes,
        legacy_property_id,
        created_at,
        modified_at,
        modified_by,
        _stg_acquired_date_parse_failed,
        _stg_disposed_date_parse_failed,
        _int_region_mismatch,
        _int_active_disposed_conflict,
        _int_unit_count_mismatch,
        current_timestamp()                                     as _dbt_loaded_at

    from property_details

)

select * from final
