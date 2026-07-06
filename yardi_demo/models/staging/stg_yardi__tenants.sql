{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__tenants
    ==================
    Cleans the RAW.TENANT table (one row per tenant, 189 rows):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTBIRTH from mixed-format TEXT to DATE via the shared
        parse_mixed_date macro (5 formats; 2-digit-year variants included)
      - Replaces magic-number ISTATUS with human-readable status
        (0 = current, 1 = former).  BACTIVE tracks ISTATUS 1:1 in the
        live data but is preserved independently as is_active.
      - Masks PII: SSSN -> last 4 only (ssn_last4); DTBIRTH retained
        (parsed) but SSN kept masked to match the vendor-model policy
      - Casts BACTIVE (NUMBER 0/1) to real BOOLEAN
      - Nullifies zero-value foreign keys (HUNIT, HLEASE) that mean
        "no record" (defensive; none present in current extract)
      - Drops denormalized text columns (SPROPNAME, SUNITCODE) resolved
        via joins in the intermediate layer
      - Preserves raw SLEASETYPE for downstream decode & audit
      - Adds a birth-date parse-failure observability flag
-#}

with source as (

    select * from {{ source('yardi', 'TENANT') }}

),

renamed as (

    select
        -- ===== Identifiers =====
        hmy                                          as tenant_id,
        scode                                        as tenant_code,

        -- ===== Foreign keys =====
        hproperty                                    as property_id,
        nullif(hunit, 0)                             as unit_id,
        nullif(hlease, 0)                            as lease_id,

        -- ===== Name =====
        sfirstname                                   as first_name,
        slastname                                    as last_name,
        sfullname                                    as full_name,

        -- ===== Contact (PII) =====
        sphone                                       as phone,
        sphone2                                      as phone_secondary,
        semail                                       as email,
        semergcontact                                as emergency_contact_name,
        semergphone                                  as emergency_contact_phone,

        -- ===== Sensitive PII (masked) =====
        right(cast(sssn as varchar), 4)              as ssn_last4,
        {{ parse_mixed_date('dtbirth') }}            as birth_date,

        -- ===== Tenancy dates =====
        dtmovein                                     as move_in_date,
        dtmoveout                                    as move_out_date,

        -- ===== Status & flags =====
        case istatus
            when 0 then 'current'
            when 1 then 'former'
            else 'unknown_' || cast(istatus as varchar)
        end                                          as tenant_status,
        istatus                                      as tenant_status_code,
        (bactive = 1)                                as is_active,

        -- ===== Financials =====
        mbalance                                     as account_balance,
        mdeposit                                     as deposit,
        mlastpayment                                 as last_payment_amount,
        dtlastpayment                                as last_payment_date,
        icreditscore                                 as credit_score,

        -- ===== Lease attributes =====
        sleasetype                                   as lease_type,

        -- ===== Free text =====
        snotes                                       as notes,

        -- ===== Audit =====
        dtcreated                                    as created_at,
        dtmodified                                   as modified_at,

        -- ===== Data-quality observability =====
        (
            dtbirth is not null
            and dtbirth != ''
            and {{ parse_mixed_date('dtbirth') }} is null
        )                                            as _stg_birth_date_parse_failed

    from source

)

select * from renamed
