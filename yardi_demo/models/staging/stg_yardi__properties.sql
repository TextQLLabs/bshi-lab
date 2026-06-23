{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__properties
    =====================
    Cleans the RAW.PROPERTY table (20 columns of issues):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DACQUIRED / DDISPOSED from TEXT to DATE (mixed formats via
        parse_mixed_date macro)
      - Casts SZIPCODE to VARCHAR and left-pads to 5 chars (RAW lost the
        leading zero on east-coast ZIPs, e.g. Boston 02101 -> 2101)
      - Maps magic-number ITYPE to a human-readable property_type
      - Casts BACTIVE / BTAXEXEMPT (NUMBER 0/1) to real BOOLEAN
      - Masks PII: SOWNERTAXID -> last 4 only (owner_tax_id_last4)
      - Nullifies zero-value FK HOWNER that means "no owner record"
      - Keeps all three identifiers (HMY natural PK, SCODE business key,
        LEGACY_PROP_ID legacy) but clearly named
      - Preserves the three raw region signals (SREGION, LEGACY_REGION_CD)
        UNTOUCHED for the intermediate layer to conform & audit
      - Adds parse-failure observability flags for both date columns
-#}

with source as (

    select * from {{ source('yardi', 'PROPERTY') }}

),

renamed as (

    select
        -- ===== Identifiers =====
        hmy                                          as property_id,
        scode                                        as property_code,
        legacy_prop_id                               as legacy_property_id,

        -- ===== Descriptive =====
        sname                                        as property_name,

        -- ===== Address =====
        saddr1                                       as address_line_1,
        saddr2                                       as address_line_2,
        scity                                        as city,
        sstate                                       as state_code,
        lpad(cast(szipcode as varchar), 5, '0')      as zip_code,
        scounty                                      as county,  -- low-quality, see flag

        -- ===== Management & ownership =====
        smgrname                                     as manager_name,
        smgremail                                    as manager_email,
        sownername                                   as owner_name,
        right(cast(sownertaxid as varchar), 4)       as owner_tax_id_last4,  -- PII masked
        nullif(howner, 0)                            as owner_id,

        -- ===== Classification =====
        case itype
            when 1 then 'Residential'
            when 2 then 'Commercial'
            when 3 then 'Mixed Use'
            else 'unknown_' || cast(itype as varchar)
        end                                          as property_type,
        itype                                        as property_type_code,
        itotalunits                                  as total_units,

        -- ===== Raw region signals (conformed downstream; kept for audit) =====
        sregion                                      as region_raw,
        legacy_region_cd                             as legacy_region_code,
        sfund                                        as fund,

        -- ===== Dates (TEXT -> DATE via mixed-format macro) =====
        {{ parse_mixed_date('dacquired') }}          as acquired_date,
        {{ parse_mixed_date('ddisposed') }}          as disposed_date,

        -- ===== Valuation =====
        mmarketvalue                                 as market_value,
        mpurchaseprice                               as purchase_price,

        -- ===== Flags =====
        (bactive = 1)                                as is_active,
        (btaxexempt = 1)                             as is_tax_exempt,

        -- ===== Free text =====
        snotes                                       as notes,

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
        )                                            as _stg_disposed_date_parse_failed,
        (scounty is null)                            as _stg_county_missing

    from source

)

select * from renamed
