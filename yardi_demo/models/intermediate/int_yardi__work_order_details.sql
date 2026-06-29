{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__work_order_details
    =============================
    Enriches the staged work order with dimension attributes (property,
    unit, tenant, vendor) that were previously denormalized as raw text
    columns in WORKORDER.  Joins are performed against staging models /
    raw sources so all upstream cleaning is inherited.

    Business logic added:
      - is_completed / is_open       (lifecycle convenience flags)
      - days_to_complete             (requested -> completed elapsed days)
      - days_to_schedule             (requested -> scheduled elapsed days)
      - is_overdue                   (scheduled in the past, still not done)
      - is_emergency                 (priority_label = 'emergency')
      - is_self_performed            (no vendor assigned)
      - sla_target_days              (priority-based response SLA)
      - is_sla_breached              (completion exceeded the SLA target)
-#}

with work_orders as (

    select * from {{ ref('stg_yardi__work_orders') }}

),

properties as (

    select
        hmy     as property_id,
        sname   as property_name,
        scity   as property_city,
        sstate  as property_state,
        sregion as property_region,
        sfund   as property_fund,
        itype   as property_type_code
    from {{ source('yardi', 'PROPERTY') }}

),

units as (

    select
        hmy        as unit_id,
        scode      as unit_code,
        sunittype  as unit_type,
        isqft      as unit_sqft
    from {{ source('yardi', 'UNIT') }}

),

tenants as (

    select
        hmy       as tenant_id,
        sfullname as tenant_name,
        scode     as tenant_code
    from {{ source('yardi', 'TENANT') }}

),

vendors as (

    select
        hmy        as vendor_id,
        sname      as vendor_name,
        scategory  as vendor_category,
        bpreferred as vendor_is_preferred
    from {{ source('yardi', 'VENDOR') }}

),

enriched as (

    select
        -- ===== Work-order core =====
        w.work_order_id,
        w.work_order_code,
        w.category,
        w.priority_label,
        w.priority_code,
        w.work_order_status,
        w.work_order_status_code,
        w.work_order_description,
        w.resolution_notes,
        w.assigned_to,

        -- ===== Lifecycle flags =====
        (w.work_order_status = 'complete')              as is_completed,
        (w.work_order_status in ('open', 'in_progress')) as is_open,
        (w.priority_label = 'emergency')                as is_emergency,
        (w.vendor_id is null)                           as is_self_performed,

        -- ===== Dates =====
        w.requested_date,
        w.scheduled_date,
        w.completed_date,

        -- ===== Elapsed-time metrics =====
        datediff('day', w.requested_date, w.completed_date) as days_to_complete,
        datediff('day', w.requested_date, w.scheduled_date) as days_to_schedule,
        (
            w.completed_date is null
            and w.scheduled_date is not null
            and w.scheduled_date < current_date()
            and w.work_order_status not in ('complete', 'cancelled')
        )                                               as is_overdue,

        -- ===== SLA logic (priority-based response targets) =====
        case w.priority_label
            when 'emergency' then 1
            when 'high'      then 3
            when 'medium'    then 7
            when 'low'       then 14
        end                                             as sla_target_days,
        case
            when w.completed_date is null then null
            else (
                datediff('day', w.requested_date, w.completed_date) >
                case w.priority_label
                    when 'emergency' then 1
                    when 'high'      then 3
                    when 'medium'    then 7
                    when 'low'       then 14
                end
            )
        end                                             as is_sla_breached,

        -- ===== Costs =====
        w.labor_cost,
        w.material_cost,
        w.total_cost,

        -- ===== Flags =====
        w.has_permission_to_enter,
        w.entry_notes,

        -- ===== Property dimension =====
        w.property_id,
        p.property_name,
        p.property_city,
        p.property_state,
        p.property_region,
        p.property_fund,

        -- ===== Unit dimension =====
        w.unit_id,
        u.unit_code,
        u.unit_type,
        u.unit_sqft,

        -- ===== Tenant dimension (nullable) =====
        w.tenant_id,
        tn.tenant_name,
        tn.tenant_code,

        -- ===== Vendor dimension (nullable; self-performed when null) =====
        w.vendor_id,
        v.vendor_name,
        v.vendor_category,
        v.vendor_is_preferred,

        -- ===== Audit =====
        w.created_at,
        w.modified_at,
        w._stg_scheduled_date_parse_failed

    from work_orders w
    left join properties p  on w.property_id = p.property_id
    left join units      u  on w.unit_id     = u.unit_id
    left join tenants    tn on w.tenant_id   = tn.tenant_id
    left join vendors    v  on w.vendor_id   = v.vendor_id

)

select * from enriched
