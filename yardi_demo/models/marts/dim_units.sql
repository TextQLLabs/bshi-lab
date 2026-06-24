{{
    config(
        materialized         = 'incremental',
        schema               = 'marts',
        unique_key           = 'unit_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    dim_units
    =========
    Analytics-ready unit dimension at the one-row-per-unit grain.  Built on
    int_yardi__unit_details (ephemeral) which resolves the property join and
    derived economics.

    Design decisions:
      - Incremental merge on unit_id using modified_at as the watermark so
        unit status / rent changes are upserted on each run.
      - All unit statuses retained (vacant, occupied, down, model, employee,
        unknown); filter is_rentable = true for revenue-relevant units.
      - Surrogate key (unit_sk) generated via dbt_utils for downstream
        snapshot / SCD compatibility.
      - Derived measures (rent_gap, rent_per_sqft, inspection flags) carried
        through for direct BI consumption.
-#}

with unit_details as (

    select * from {{ ref('int_yardi__unit_details') }}

    {% if is_incremental() %}
    where modified_at > (select max(modified_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['unit_id']) }}  as unit_sk,

        -- ===== Natural key =====
        unit_id,
        unit_code,

        -- ===== Descriptive attributes =====
        unit_type,
        floor_plan,
        building,
        floor_number,
        unit_size_band,

        -- ===== Physical measures =====
        square_feet,
        bedrooms,
        bathrooms,

        -- ===== Status =====
        unit_status,
        unit_status_code,
        is_rentable,
        is_occupied,
        is_vacant,

        -- ===== Economics =====
        market_rent,
        actual_rent,
        deposit,
        rent_gap,
        rent_gap_pct,
        market_rent_per_sqft,

        -- ===== Flags =====
        is_handicap_accessible,
        is_furnished,

        -- ===== Inspection =====
        available_date,
        last_inspection_date,
        days_since_last_inspection,
        inspection_is_overdue,

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
        _stg_last_inspection_parse_failed,
        current_timestamp()                                  as _dbt_loaded_at

    from unit_details

)

select * from final
