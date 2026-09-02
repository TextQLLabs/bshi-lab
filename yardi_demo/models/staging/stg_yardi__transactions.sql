{{
    config(
        materialized = 'view'
    )
}}

/*
    Staging: RAW.TRANS -> stg_yardi__transactions

    One row per financial transaction (2,000 rows). 1:1 with the source.

    Responsibilities:
      - rename Hungarian-notation columns to snake_case business names
      - cast 0/1 integer flags to boolean
      - decode the ISTATUS magic number via seed_transaction_status
      - parse the mixed-format TEXT date DTEFFECTIVE
      - drop the 7 denormalized text columns (resolved by join downstream)

    Deliberately NOT done here: no filtering. Voided and non-posted rows are
    carried through with flags so this layer stays auditable 1:1 against RAW.
*/

with source as (

    select * from {{ source('yardi', 'TRANS') }}

),

status_lookup as (

    select * from {{ ref('seed_transaction_status') }}

),

renamed as (

    select
        -- identifiers
        s.HMY                                   as transaction_id,
        s.HPROPERTY                             as property_id,
        s.HUNIT                                 as unit_id,
        s.HTENANT                               as tenant_id,
        s.HLEASE                                as lease_id,
        s.HBATCH                                as batch_id,
        s.HGLACCT                               as gl_account_id,
        s.HCHARGE                               as charge_id,
        s.HVENDOR                               as vendor_id,

        -- transaction descriptors
        s.SCODE                                 as transaction_code,
        upper(trim(s.STYPE))                    as transaction_type,
        s.SDESC                                 as transaction_description,
        s.SREF                                  as reference,
        s.SCHECKNO                              as check_number,
        s.SBANKACCT                             as bank_account,

        -- status
        s.ISTATUS                               as transaction_status_code,
        st.transaction_status                   as transaction_status,
        coalesce(s.BVOID, 0) = 1                as is_voided,

        -- dates
        s.DTTRANSACTION                         as transaction_date,
        s.DTPOSTED                              as posted_date,
        {{ parse_mixed_date('s.DTEFFECTIVE') }} as effective_date,
        s.IPERIOD                               as accounting_period,

        -- measures
        s.MAMOUNT                               as amount,
        s.MTAX                                  as tax_amount,
        s.MTOTAL                                as total_amount,
        s.MBALANCE                              as running_balance,

        -- audit
        s.SCREATEDBY                            as created_by,
        s.DTCREATED                             as created_at,

        -- data-quality flag
        (
            s.DTEFFECTIVE is not null
            and trim(s.DTEFFECTIVE) <> ''
            and {{ parse_mixed_date('s.DTEFFECTIVE') }} is null
        )                                       as _stg_effective_date_parse_failed

    from source s
    left join status_lookup st
        on s.ISTATUS = st.transaction_status_code

)

select * from renamed
