{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__prospect_funnel
    ==========================
    Enriches the staged prospect with property/unit attributes and derives
    leasing-funnel analytics.  Joins against staging/source models and the
    seed_prospect_status lookup so all upstream cleaning is inherited.

    Business logic added:
      - funnel_stage_order / is_active_lead / is_converted (from seed)
      - reached_tour / reached_application / reached_approval / reached_lease
        boolean funnel-progression flags
      - days_to_tour      (contact -> show)
      - days_to_apply     (contact -> applied)
      - days_to_movein    (applied -> move-in)
      - lead_age_days     (contact -> COALESCE(move-in, modified, today))
      - contact_month     (month-truncated cohort key)
-#}

with prospects as (

    select * from {{ ref('stg_yardi__prospects') }}

),

status_lookup as (

    select * from {{ ref('seed_prospect_status') }}

),

properties as (

    select
        hmy     as property_id,
        sname   as property_name,
        scity   as property_city,
        sstate  as property_state,
        sregion as property_region,
        sfund   as property_fund
    from {{ source('yardi', 'PROPERTY') }}

),

units as (

    select
        hmy        as unit_id,
        scode      as unit_code,
        sunittype  as unit_type,
        ibedrooms  as unit_bedrooms,
        mmarketrent as unit_market_rent
    from {{ source('yardi', 'UNIT') }}

),

enriched as (

    select
        -- ===== Prospect core =====
        p.prospect_id,
        p.first_name,
        p.last_name,
        p.full_name,
        p.phone,
        p.email,
        p.lead_source,
        p.leasing_agent,
        p.desired_bedrooms,
        p.desired_rent,

        -- ===== Status (staging + seed) =====
        p.prospect_status,
        p.prospect_status_code,
        s.funnel_stage_order,
        s.is_active_lead,
        s.is_converted,

        -- ===== Funnel dates =====
        p.contact_date,
        p.show_date,
        p.applied_date,
        p.approved_date,
        p.denied_date,
        p.move_in_date,
        date_trunc('month', p.contact_date)             as contact_month,

        -- ===== Funnel progression flags =====
        (p.show_date    is not null)                    as reached_tour,
        (p.applied_date is not null)                    as reached_application,
        (p.approved_date is not null)                   as reached_approval,
        (p.move_in_date is not null)                    as reached_lease,

        -- ===== Velocity metrics =====
        datediff('day', p.contact_date, p.show_date)    as days_to_tour,
        datediff('day', p.contact_date, p.applied_date) as days_to_apply,
        datediff('day', p.applied_date, p.move_in_date) as days_to_movein,
        datediff(
            'day',
            p.contact_date,
            coalesce(p.move_in_date, p.modified_at::date, current_date())
        )                                               as lead_age_days,

        -- ===== Property dimension =====
        p.property_id,
        pr.property_name,
        pr.property_city,
        pr.property_state,
        pr.property_region,
        pr.property_fund,

        -- ===== Unit dimension (nullable) =====
        p.unit_id,
        u.unit_code,
        u.unit_type,
        u.unit_bedrooms,
        u.unit_market_rent,

        -- ===== Audit =====
        p.notes,
        p.created_at,
        p.modified_at,
        p._stg_show_date_parse_failed

    from prospects p
    left join status_lookup s on p.prospect_status_code = s.prospect_status_code
    left join properties   pr on p.property_id          = pr.property_id
    left join units        u  on p.unit_id              = u.unit_id

)

select * from enriched
