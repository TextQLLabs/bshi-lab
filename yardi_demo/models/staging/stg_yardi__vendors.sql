with source as (

    select * from {{ source('yardi', 'VENDOR') }}

),

renamed as (

    select
        -- keys
        HMY                                             as vendor_id,
        SCODE                                           as vendor_code,

        -- attributes
        SNAME                                           as vendor_name,
        SCATEGORY                                       as vendor_category,   -- raw, decoded downstream
        S1099TYPE                                       as tax_1099_type,     -- raw, decoded downstream

        -- geography
        SSTATE                                          as state_code,
        -- SZIPCODE is NUMBER in RAW; restore leading zeros lost on load
        case
            when SZIPCODE is null then null
            else lpad(SZIPCODE::varchar, 5, '0')
        end                                             as zip_code,

        -- PII: mask vendor EIN to last 4 digits only
        case
            when STAXID is null then null
            else right(regexp_replace(STAXID, '[^0-9]', ''), 4)
        end                                             as tax_id_last4,

        -- insurance
        {{ parse_mixed_date('DTINSEXPIRES') }}          as insurance_expiry_date,

        -- booleans
        (BACTIVE = 1)                                   as is_active,
        (BPREFERRED = 1)                                as is_preferred,

        -- money
        MYTDPAID                                        as ytd_paid,

        -- raw presence helpers (not selected downstream)
        nullif(trim(SINSURANCEPOLICY), '')              as _insurance_policy_raw,
        nullif(trim(DTINSEXPIRES), '')                  as _insurance_expiry_raw

    from source

),

flagged as (

    select
        vendor_id,
        vendor_code,
        vendor_name,
        vendor_category,
        tax_1099_type,
        state_code,
        zip_code,
        tax_id_last4,
        insurance_expiry_date,
        is_active,
        is_preferred,
        ytd_paid,

        -- DQ: DTINSEXPIRES was non-empty but no known format parsed
        (_insurance_expiry_raw is not null
            and insurance_expiry_date is null)          as _stg_insurance_expiry_parse_failed,

        -- DQ: policy number and expiry presence disagree (XOR)
        ((_insurance_policy_raw is not null)
            != (_insurance_expiry_raw is not null))     as _stg_insurance_incomplete

    from renamed

)

select * from flagged
