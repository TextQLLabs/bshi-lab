{{
    config(
        materialized  = 'incremental',
        schema        = 'marts',
        unique_key    = 'work_order_id',
        incremental_strategy = 'merge',
        on_schema_change     = 'sync_all_columns'
    )
}}

{#-
    fct_work_orders
    ===============
    Analytics-ready maintenance work-order fact at the individual
    work-order grain.  Built on int_yardi__work_order_details (ephemeral)
    which resolves all dimension joins and SLA logic.

    Design decisions:
      - Incremental merge on work_order_id using modified_at as the
        watermark, so late status/cost updates (e.g. an open work order
        that later completes) are picked up on subsequent runs.
      - Cancelled work orders are KEPT (work_order_status = 'cancelled')
        so downstream consumers can audit them; filter as needed.
      - Dimension FKs are retained alongside denormalized attributes so the
        table serves both as a wide fact and as a joinable fact.
      - Surrogate key (work_order_sk) generated via dbt_utils.
-#}

with work_order_details as (

    select * from {{ ref('int_yardi__work_order_details') }}

    {% if is_incremental() %}
    where modified_at > (select max(modified_at) from {{ this }})
    {% endif %}

),

final as (

    select
        -- ===== Surrogate key =====
        {{ dbt_utils.generate_surrogate_key([
            'work_order_id'
        ]) }}                                       as work_order_sk,

        -- ===== Natural key =====
        work_order_id,
        work_order_code,

        -- ===== Classification =====
        category,
        priority_label,
        priority_code,
        work_order_status,
        work_order_status_code,
        work_order_description,

        -- ===== Lifecycle flags =====
        is_completed,
        is_open,
        is_overdue,
        is_emergency,
        is_self_performed,

        -- ===== Dates =====
        requested_date,
        scheduled_date,
        completed_date,

        -- ===== Elapsed-time / SLA measures =====
        days_to_schedule,
        days_to_complete,
        sla_target_days,
        is_sla_breached,

        -- ===== Cost measures =====
        labor_cost,
        material_cost,
        total_cost,

        -- ===== Operational detail =====
        assigned_to,
        has_permission_to_enter,
        resolution_notes,

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

        -- ===== Tenant dimension (nullable) =====
        tenant_id,
        tenant_name,
        tenant_code,

        -- ===== Vendor dimension (nullable) =====
        vendor_id,
        vendor_name,
        vendor_category,
        vendor_is_preferred,

        -- ===== Audit =====
        created_at,
        modified_at,
        _stg_scheduled_date_parse_failed,
        current_timestamp()                         as _dbt_loaded_at

    from work_order_details

)

select * from final
