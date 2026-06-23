{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__vendors
    ==================
    Cleans the RAW.VENDOR table:
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTINSEXPIRES from TEXT to DATE (5 mixed formats via the
        shared parse_mixed_date macro)
      - Casts SZIPCODE to VARCHAR and left-pads to 5 chars (RAW lost the
        leading zero on east-coast ZIPs, e.g. Boston 02101 -> 2101)
      - Casts BACTIVE / BPREFERRED (NUMBER 0/1) to real BOOLEAN
      - Masks PII: STAXID (vendor EIN) -> last 4 only (tax_id_last4)
      - Keeps both identifiers (HMY natural PK, SCODE business key) and the
        LEGACY_VENDOR_ID, clearly named
      - Preserves raw SCATEGORY / S1099TYPE for downstream decode & audit
      - Adds parse-failure + insurance-completeness observability flags
-#}

with source as (

    select * from {{ source('yardi', 'VENDOR') }}

),

renamed as (

    select
        -- ===== Identifiers =====
        hmy                                          as vendor_id,
        scode                                        as vendor_code,
        legacy_vendor_id                             as legacy_vendor_id,

        -- ===== Descriptive =====
        sname                                        as vendor_name,
        scategory                                    as category_raw,

        -- ===== Address =====
        saddr1                                       as address_line_1,
        saddr2                                       as address_line_2,
        scity                                        as city,
        sstate                                       as state_code,
        lpad(cast(szipcode as varchar), 5, '0')      as zip_code,

        -- ===== Contact =====
        sphone                                       as phone,
        sfax                                         as fax,
        semail                                       as email,

        -- ===== Tax / 1099 =====
        right(cast(staxid as varchar), 4)            as tax_id_last4,   -- PII masked (EIN)
        s1099type                                    as form_1099_type,
        m1099amt                                     as form_1099_amount,

        -- ===== Insurance =====
        sinsurancepolicy                             as insurance_policy_number,
        {{ parse_mixed_date('dtinsexpires') }}       as insurance_expiry_date,

        -- ===== Flags =====
        (bactive = 1)                                as is_active,
        (bpreferred = 1)                             as is_preferred,

        -- ===== Spend =====
        mytdpaid                                     as ytd_paid,

        -- ===== Free text =====
        snotes                                       as notes,

        -- ===== Audit =====
        dtcreated                                    as created_at,
        dtmodified                                   as modified_at,

        -- ===== Data-quality observability =====
        (
            dtinsexpires is not null
            and dtinsexpires != ''
            and {{ parse_mixed_date('dtinsexpires') }} is null
        )                                            as _stg_insurance_expiry_parse_failed,
        (
            (sinsurancepolicy is null) != (dtinsexpires is null)
        )                                            as _stg_insurance_incomplete

    from source

)

select * from renamed
