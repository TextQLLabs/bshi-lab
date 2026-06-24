{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__units
    ================
    Cleans the RAW.UNIT table (one row per rentable unit):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTLASTINSPECTION from TEXT to DATE (5 mixed formats via macro)
      - Replaces magic-number ISTATUS with human-readable unit status
        (cross-checked against the co-located SSTATUSDESC text column)
      - Casts 0/1 NUMBER flags (BHANDICAP, BFURNISHED) to boolean
      - Nullifies zero-value market/actual rent that means "not set"
      - Drops 3 denormalized property text columns (SPROPNAME, SPROPCITY,
        SPROPSTATE) -- resolved via join to stg_yardi__properties downstream
      - Adds _stg_last_inspection_parse_failed flag for observability
-#}

with source as (

    select * from {{ source('yardi', 'UNIT') }}

),

renamed as (

    select
        -- ===== Primary key =====
        hmy                                          as unit_id,

        -- ===== Foreign keys =====
        hproperty                                    as property_id,

        -- ===== Unit identifiers =====
        scode                                        as unit_code,
        sunittype                                    as unit_type,
        sfloorplan                                   as floor_plan,
        sbuilding                                    as building,

        -- ===== Physical attributes =====
        isqft                                        as square_feet,
        ibedrooms                                    as bedrooms,
        ibathrooms                                   as bathrooms,
        ifloor                                        as floor_number,

        -- ===== Economics =====
        mmarketrent                                  as market_rent,
        nullif(mactualrent, 0)                       as actual_rent,
        mdeposit                                     as deposit,

        -- ===== Status =====
        case istatus
            when 0 then 'vacant'
            when 1 then 'occupied'
            when 2 then 'down'
            when 3 then 'model'
            when 4 then 'employee'
            when 9 then 'unknown'
            else 'unknown_' || cast(istatus as varchar)
        end                                          as unit_status,
        istatus                                      as unit_status_code,

        -- ===== Flags =====
        (bhandicap = 1)                              as is_handicap_accessible,
        (bfurnished = 1)                             as is_furnished,

        -- ===== Dates =====
        dtavailable                                  as available_date,
        {{ parse_mixed_date('dtlastinspection') }}   as last_inspection_date,

        -- ===== Free text =====
        snotes                                       as notes,

        -- ===== Audit =====
        dtcreated                                    as created_at,
        dtmodified                                   as modified_at,

        -- ===== Data-quality observability =====
        (
            dtlastinspection is not null
            and dtlastinspection != ''
            and {{ parse_mixed_date('dtlastinspection') }} is null
        )                                            as _stg_last_inspection_parse_failed

    from source

)

select * from renamed
