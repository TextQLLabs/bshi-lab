{{
    config(
        materialized  = 'incremental',
        schema        = 'marts',
        unique_key    = 'prospect_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    fct_prospects
    =============
    Analytics-ready leasing-funnel fact at the individual-prospect grain.
    Built on int_yardi__prospect_funnel (ephemeral) which resolves all
    dimension joins and funnel logic.

    Design decisions:
      - Incremental merge on prospect_id using modified_at as the watermark,
        so prospects that advance through the funnel (status changes,
        application/approval/move-in dates added) are updated in place.
      - All funnel-progression flags and velocity metrics are retained so
        the table serves both conversion-rate reporting and cohort analysis.
      - Property/unit FKs are kept alongside denormalized attributes so the
        fact works as a wide table and as a joinable fact.
      - Surrogate key (prospect_sk) generated via dbt_utils.
-#}

with prospect_funnel as (

    select * from {{ ref('int_yardi__prospect_funnel') }}

    {% if is_incremental() %}
    where modified_at > (select max(modified_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key(['prospect_id']) }} as prospect_sk,

        -- ===== Natural key =====
        prospect_id,

        -- ===== Prospect attributes =====
        full_name,
        phone,
        email,
        lead_source,
        leasing_agent,
        desired_bedrooms,
        desired_rent,

        -- ===== Funnel status =====
        prospect_status,
        prospect_status_code,
        funnel_stage_order,
        is_active_lead,
        is_converted,

        -- ===== Funnel dates =====
        contact_date,
        show_date,
        applied_date,
        approved_date,
        denied_date,
        move_in_date,
        contact_month,

        -- ===== Funnel progression flags =====
        reached_tour,
        reached_application,
        reached_approval,
        reached_lease,

        -- ===== Velocity measures =====
        days_to_tour,
        days_to_apply,
        days_to_movein,
        lead_age_days,

        -- ===== Property dimension =====
        property_id,
        property_name,
        property_city,
        property_state,
        property_region,
        property_fund,

        -- ===== Unit dimension (nullable) =====
        unit_id,
        unit_code,
        unit_type,
        unit_bedrooms,
        unit_market_rent,

        -- ===== Audit =====
        notes,
        created_at,
        modified_at,
        _stg_show_date_parse_failed,
        current_timestamp()                         as _dbt_loaded_at

    from prospect_funnel

)

select * from final
