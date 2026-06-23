{{
    config(
        materialized = 'view'
    )
}}

{#-
    stg_yardi__transactions
    =======================
    Cleans the RAW.TRANS table:
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTEFFECTIVE from TEXT to DATE (5 mixed formats via macro)
      - Casts SCHECKNO and SGLACCTCODE from NUMBER to VARCHAR (identifiers)
      - Replaces magic-number ISTATUS with human-readable status
      - Replaces magic-number BVOID with boolean
      - Nullifies zero-value foreign keys (HVENDOR) that mean "no vendor"
      - Drops 7 denormalized text columns (SPROPNAME, STENANTNAME,
        SUNITCODE, SGLACCTCODE, SGLACCTDESC, SCHARGECODE, SCHARGEDESC)
        -- these are resolved via joins in the intermediate layer
      - Adds _stg_effective_date_parse_failed flag for observability
-#}

with source as (

    select * from {{ source('yardi', 'TRANS') }}

),

renamed as (

    select
        -- ===== Primary key =====
        hmy                                         as transaction_id,

        -- ===== Foreign keys =====
        hproperty                                   as property_id,
        hunit                                       as unit_id,
        htenant                                     as tenant_id,
        hlease                                      as lease_id,
        hbatch                                      as batch_id,
        hglacct                                     as gl_account_id,
        hcharge                                     as charge_id,
        nullif(hvendor, 0)                          as vendor_id,

        -- ===== Transaction identifiers =====
        scode                                       as transaction_code,
        stype                                       as transaction_type,
        sdesc                                       as transaction_description,

        -- ===== Dates =====
        dttransaction                               as transaction_date,
        dtposted                                    as posted_date,
        {{ parse_mixed_date('dteffective') }}       as effective_date,
        iperiod                                     as fiscal_period,

        -- ===== Monetary amounts =====
        mamount                                     as amount,
        mtax                                        as tax_amount,
        mtotal                                      as total_amount,
        mbalance                                    as running_balance,

        -- ===== Status & flags =====
        case istatus
            when 0 then 'posted'
            when 1 then 'pending'
            when 2 then 'reversed'
            when 3 then 'archived'
            else 'unknown_' || cast(istatus as varchar)
        end                                         as transaction_status,
        istatus                                     as transaction_status_code,
        (bvoid = 1)                                 as is_voided,

        -- ===== Payment details =====
        nullif(cast(scheckno as varchar), '0')      as check_number,
        sref                                        as reference_number,
        sbankacct                                   as bank_account_masked,
        snotes                                      as notes,

        -- ===== Audit =====
        dtcreated                                   as created_at,
        screatedby                                  as created_by,

        -- ===== Data-quality observability =====
        (
            dteffective is not null
            and dteffective != ''
            and {{ parse_mixed_date('dteffective') }} is null
        )                                           as _stg_effective_date_parse_failed

    from source

)

select * from renamed
