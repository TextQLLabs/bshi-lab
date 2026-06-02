{{
  config(
    materialized='view',
    schema='staging'
  )
}}

{#-
  stg_transactions.sql
  Cleans RAW.TRANS from Yardi Voyager:
    - Renames Hungarian-notation columns to snake_case
    - Parses DTEFFECTIVE from 5 inconsistent string formats into a proper DATE
    - Decodes magic-number ISTATUS (0/1/2/3) and BVOID (0/1) into human-readable labels
    - Decodes STYPE codes (CHG/PMT/CR/ADJ) into descriptive transaction_type
    - Drops 7 denormalized columns (SPROPNAME, STENANTNAME, SUNITCODE, etc.)
    - Casts SCHECKNO from NUMBER to VARCHAR (it's a check number, not a quantity)
    - Adds is_void, is_credit, and net_amount computed columns
-#}

with source as (

    select * from {{ source('yardi', 'TRANS') }}

),

parsed as (

    select
        -- === Primary & Foreign Keys ===
        hmy                                         as transaction_id,
        hproperty                                   as property_id,
        hunit                                       as unit_id,
        htenant                                     as tenant_id,
        hlease                                      as lease_id,
        hbatch                                      as batch_id,
        hglacct                                     as gl_account_id,
        hcharge                                     as charge_code_id,
        hvendor                                     as vendor_id,

        -- === Transaction Identity ===
        scode                                       as transaction_code,

        -- Decode STYPE magic codes
        stype                                       as transaction_type_code,
        case stype
            when 'CHG' then 'Charge'
            when 'PMT' then 'Payment'
            when 'CR'  then 'Credit'
            when 'ADJ' then 'Adjustment'
            else 'Unknown (' || stype || ')'
        end                                         as transaction_type,

        sdesc                                       as transaction_description,

        -- === Dates ===
        -- DTTRANSACTION and DTPOSTED are already proper DATE columns
        dttransaction                               as transaction_date,
        dtposted                                    as posted_date,

        -- DTEFFECTIVE is a TEXT column with 5 inconsistent formats:
        --   MM/DD/YY     (426 rows)  e.g. 08/27/24
        --   MM-DD-YYYY   (408 rows)  e.g. 05-18-2024
        --   DD-Mon-YYYY  (404 rows)  e.g. 01-Apr-2022
        --   MM/DD/YYYY   (401 rows)  e.g. 10/25/2023
        --   YYYY-MM-DD   (361 rows)  e.g. 2022-01-10
        case
            when dteffective rlike '^\\d{4}-\\d{2}-\\d{2}$'
                then to_date(dteffective, 'YYYY-MM-DD')
            when dteffective rlike '^\\d{2}/\\d{2}/\\d{4}$'
                then to_date(dteffective, 'MM/DD/YYYY')
            when dteffective rlike '^\\d{2}/\\d{2}/\\d{2}$'
                then to_date(dteffective, 'MM/DD/YY')
            when dteffective rlike '^\\d{2}-[A-Za-z]{3}-\\d{4}$'
                then to_date(dteffective, 'DD-MON-YYYY')
            when dteffective rlike '^\\d{2}-\\d{2}-\\d{4}$'
                then to_date(dteffective, 'MM-DD-YYYY')
            else null  -- fail safe: surface as NULL rather than error
        end                                         as effective_date,

        -- Flag rows where DTEFFECTIVE could not be parsed
        case
            when dteffective is not null
                 and not (
                     dteffective rlike '^\\d{4}-\\d{2}-\\d{2}$'
                     or dteffective rlike '^\\d{2}/\\d{2}/\\d{4}$'
                     or dteffective rlike '^\\d{2}/\\d{2}/\\d{2}$'
                     or dteffective rlike '^\\d{2}-[A-Za-z]{3}-\\d{4}$'
                     or dteffective rlike '^\\d{2}-\\d{2}-\\d{4}$'
                 )
            then true
            else false
        end                                         as is_effective_date_unparseable,

        -- === Period ===
        iperiod                                     as fiscal_period,

        -- === Monetary Amounts ===
        mamount                                     as amount,
        mtax                                        as tax_amount,
        mtotal                                      as total_amount,
        mbalance                                    as running_balance,

        -- === Status Fields ===
        -- Decode ISTATUS magic numbers
        istatus                                     as status_code,
        case istatus
            when 0 then 'Posted'
            when 1 then 'Pending'
            when 2 then 'Void'
            when 3 then 'Reversed'
            else 'Unknown (' || istatus::varchar || ')'
        end                                         as status_description,

        -- Decode BVOID boolean flag
        case bvoid
            when 1 then true
            else false
        end                                         as is_void,

        -- === Computed Columns ===
        case when mamount < 0 then true else false end  as is_credit,
        case when bvoid = 1 then 0 else mamount end     as net_amount,

        -- === Payment Details ===
        scheckno::varchar                           as check_number,
        sref                                        as reference_number,
        sbankacct                                   as bank_account_masked,
        snotes                                      as notes,

        -- === Audit ===
        dtcreated                                   as created_at,
        screatedby                                  as created_by

        -- DROPPED denormalized columns (resolve via joins in marts):
        --   SPROPNAME, STENANTNAME, SUNITCODE,
        --   SGLACCTCODE, SGLACCTDESC, SCHARGECODE, SCHARGEDESC

    from source

)

select * from parsed
