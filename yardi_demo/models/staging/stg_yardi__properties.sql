{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__properties
    =====================
    Cleans the RAW.PROPERTY table (one row per property):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts SZIPCODE from NUMBER to a 5-char VARCHAR, restoring leading
        zeros lost by numeric storage (e.g. Boston 2101 -> '02101')
      - Casts DACQUIRED / DDISPOSED from TEXT to DATE (5 mixed formats via macro)
      - Replaces magic-number ITYPE with human-readable property_type
      - Casts 0/1 NUMBER flags (BACTIVE, BTAXEXEMPT) to boolean
      - Masks the sensitive owner tax id (keeps last 4 only)
      - Nullifies zero-value owner FK (HOWNER) that means "no owner record"
      - Empty-string address line 2 / dispose date normalised to NULL
      - Keeps SREGION as region_reported (UNRELIABLE -- conformed downstream
        in int_yardi__property_details from state); keeps LEGACY_REGION_CD raw
      - Adds _stg_*_date_parse_failed flags for observability
-#}

with source as (

    select * from {{ source('yardi', 'PROPERTY') }}

),

renamed as (

    select
        -- ===== Primary key =====
        hmy                                          as property_id,

        -- ===== Natural key / identifiers =====
        scode                                        as property_code,
        sname                                        as property_name,

        -- ===== Address =====
        saddr1                                       as address_line_1,
        nullif(saddr2, '')                           as address_line_2,
        scity                                        as city,
        sstate                                       as state,
        lpad(cast(szipcode as varchar), 5, '0')      as zip_code,
        scounty                                      as county,

        -- ===== Management contacts =====
        smgrname                                     as manager_name,
        smgremail                                    as manager_email,

        -- ===== Ownership =====
        sownername                                   as owner_name,
        nullif(howner, 0)                            as owner_id,
        case
            when sownertaxid is not null
            then '**-***' || right(sownertaxid, 4)
        end                                          as owner_tax_id_masked,

        -- ===== Type =====
        case itype
            when 1 then 'Residential'
            when 2 then 'Commercial'
            when 3 then 'Mixed Use'
            else 'unknown_' || cast(itype as varchar)
        end                                          as property_type,
        itype                                        as property_type_code,

        -- ===== Size (reported; see DQ note) =====
        itotalunits                                  as reported_total_units,

        -- ===== Dates =====
        {{ parse_mixed_date('dacquired') }}          as acquired_date,
        {{ parse_mixed_date('ddisposed') }}          as disposed_date,

        -- ===== Economics =====
        mmarketvalue                                 as market_value,
        mpurchaseprice                               as purchase_price,

        -- ===== Segmentation =====
        sregion                                      as region_reported,
        sfund                                        as fund,

        -- ===== Flags =====
        (bactive = 1)                                as is_active,
        (btaxexempt = 1)                             as is_tax_exempt,

        -- ===== Free text =====
        snotes                                       as notes,

        -- ===== Legacy identifiers =====
        legacy_prop_id                               as legacy_property_id,
        legacy_region_cd                             as legacy_region_code,

        -- ===== Audit =====
        dtcreated                                    as created_at,
        dtmodified                                   as modified_at,
        smodifiedby                                  as modified_by,

        -- ===== Data-quality observability =====
        (
            dacquired is not null
            and dacquired != ''
            and {{ parse_mixed_date('dacquired') }} is null
        )                                            as _stg_acquired_date_parse_failed,
        (
            ddisposed is not null
            and ddisposed != ''
            and {{ parse_mixed_date('ddisposed') }} is null
        )                                            as _stg_disposed_date_parse_failed

    from source

)

select * from renamed
