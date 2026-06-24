{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__unit_details
    =======================
    Enriches the staged unit with its parent property attributes and adds
    derived leasing/economic business logic.  Joins against staging models
    so all upstream cleaning is inherited.

    Business logic added:
      - is_rentable / is_occupied / is_vacant  (status groupings)
      - rent_gap / rent_gap_pct                (market vs actual rent)
      - rent_per_sqft                          (market rent / square_feet)
      - unit_size_band                         (studio/small/medium/large)
      - days_since_last_inspection
      - inspection_is_overdue                  (> 365 days or never)
-#}

with units as (

    select * from {{ ref('stg_yardi__units') }}

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

enriched as (

    select
        -- ===== Unit core =====
        u.unit_id,
        u.unit_code,
        u.unit_type,
        u.floor_plan,
        u.building,
        u.floor_number,

        -- ===== Physical =====
        u.square_feet,
        u.bedrooms,
        u.bathrooms,
        case
            when u.square_feet < 600  then 'studio'
            when u.square_feet < 1000 then 'small'
            when u.square_feet < 1500 then 'medium'
            else 'large'
        end                                             as unit_size_band,

        -- ===== Status & groupings =====
        u.unit_status,
        u.unit_status_code,
        (u.unit_status in ('vacant', 'occupied'))       as is_rentable,
        (u.unit_status = 'occupied')                    as is_occupied,
        (u.unit_status = 'vacant')                      as is_vacant,

        -- ===== Economics =====
        u.market_rent,
        u.actual_rent,
        u.deposit,
        (u.market_rent - coalesce(u.actual_rent, 0))    as rent_gap,
        case
            when u.market_rent > 0 and u.actual_rent is not null
            then round((u.market_rent - u.actual_rent) / u.market_rent, 4)
        end                                             as rent_gap_pct,
        case
            when u.square_feet > 0
            then round(u.market_rent / u.square_feet, 2)
        end                                             as market_rent_per_sqft,

        -- ===== Flags =====
        u.is_handicap_accessible,
        u.is_furnished,

        -- ===== Inspection =====
        u.available_date,
        u.last_inspection_date,
        datediff('day', u.last_inspection_date, current_date())
                                                        as days_since_last_inspection,
        (
            u.last_inspection_date is null
            or datediff('day', u.last_inspection_date, current_date()) > 365
        )                                               as inspection_is_overdue,

        -- ===== Property dimension =====
        u.property_id,
        p.property_name,
        p.property_city,
        p.property_state,
        p.property_region,
        p.property_fund,

        -- ===== Audit / DQ =====
        u.notes,
        u.created_at,
        u.modified_at,
        u._stg_last_inspection_parse_failed

    from units u
    left join properties p on u.property_id = p.property_id

)

select * from enriched
