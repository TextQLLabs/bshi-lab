{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__tenant_details
    =========================
    Enriches the staged tenant with parent property attributes, its current
    unit, and lease terms, and adds derived tenancy/financial business logic.
    Joins against staging / source models so all upstream cleaning is
    inherited.

    Birth-date century correction
    -----------------------------
    RAW.TENANT.DTBIRTH contains 2-digit-year formats (e.g. '11/15/99',
    '12/08/00').  Snowflake's TRY_TO_DATE(..,'MM/DD/YY') parses these into
    literal years 0060-0099 / 0000, producing nonsense ages (validated:
    45 of 189 tenants landed in years 0000-0099).  We shift any parsed year
    below 100 into a sensible window: year <= 25 -> 2000s, else -> 1900s.
    A _birth_century_imputed flag records which rows were corrected.

    Business logic added:
      - is_current / is_former                 (status groupings)
      - tenure_days / tenure_months            (move-in to move-out or today)
      - is_delinquent / is_in_credit           (from account_balance sign)
      - balance_status                         (delinquent/credit/clear)
      - age_years                              (from century-corrected birth_date,
                                                guarded to plausible 18-100)
      - credit_band                            (poor/fair/good/excellent)
      - days_since_last_payment
-#}

with tenants as (

    select * from {{ ref('stg_yardi__tenants') }}

),

birth_corrected as (

    select
        tenant_id,
        birth_date as birth_date_raw,
        case
            when birth_date is null then null
            when year(birth_date) < 100 then
                dateadd(
                    'year',
                    case when year(birth_date) <= 25 then 2000 else 1900 end,
                    birth_date
                )
            else birth_date
        end                                              as birth_date,
        (birth_date is not null and year(birth_date) < 100)
                                                         as _birth_century_imputed
    from tenants

),

properties as (

    select
        hmy     as property_id,
        sname   as property_name,
        scity   as property_city,
        sstate  as property_state,
        sregion as property_region,
        sfund   as property_fund
    from {{ source('yardi', 'PROPERTY') }}

),

units as (

    select
        hmy       as unit_id,
        scode     as unit_code,
        sunittype as unit_type,
        isqft     as square_feet
    from {{ source('yardi', 'UNIT') }}

),

leases as (

    select
        hmy         as lease_id,
        stype       as lease_term_type,
        dtleasefrom as lease_from_date,
        dtleaseto   as lease_to_date,
        mrent       as lease_rent
    from {{ source('yardi', 'LEASE') }}

),

enriched as (

    select
        -- ===== Tenant core =====
        t.tenant_id,
        t.tenant_code,
        t.first_name,
        t.last_name,
        t.full_name,

        -- ===== Contact (PII) =====
        t.phone,
        t.email,
        t.emergency_contact_name,
        t.emergency_contact_phone,
        t.ssn_last4,

        -- ===== Demographics (century-corrected) =====
        bc.birth_date,
        case
            when bc.birth_date is not null
                 and floor(datediff('day', bc.birth_date, current_date()) / 365.25)
                     between 18 and 100
            then floor(datediff('day', bc.birth_date, current_date()) / 365.25)
        end                                              as age_years,

        -- ===== Status & groupings =====
        t.tenant_status,
        t.tenant_status_code,
        t.is_active,
        (t.tenant_status = 'current')                    as is_current,
        (t.tenant_status = 'former')                     as is_former,

        -- ===== Tenancy dates & tenure =====
        t.move_in_date,
        t.move_out_date,
        datediff(
            'day',
            t.move_in_date,
            coalesce(t.move_out_date, current_date())
        )                                                as tenure_days,
        round(
            datediff(
                'month',
                t.move_in_date,
                coalesce(t.move_out_date, current_date())
            ), 0
        )                                                as tenure_months,

        -- ===== Financials =====
        t.account_balance,
        t.deposit,
        t.last_payment_amount,
        t.last_payment_date,
        datediff('day', t.last_payment_date, current_date())
                                                         as days_since_last_payment,
        (t.account_balance > 0)                          as is_delinquent,
        (t.account_balance < 0)                          as is_in_credit,
        case
            when t.account_balance > 0 then 'delinquent'
            when t.account_balance < 0 then 'credit'
            else 'clear'
        end                                              as balance_status,

        -- ===== Credit =====
        t.credit_score,
        case
            when t.credit_score is null      then 'unknown'
            when t.credit_score < 580        then 'poor'
            when t.credit_score < 670        then 'fair'
            when t.credit_score < 740        then 'good'
            else 'excellent'
        end                                              as credit_band,

        -- ===== Lease attributes =====
        t.lease_type,
        l.lease_term_type,
        l.lease_from_date,
        l.lease_to_date,
        l.lease_rent,

        -- ===== Unit dimension =====
        t.unit_id,
        un.unit_code,
        un.unit_type,
        un.square_feet,

        -- ===== Property dimension =====
        t.property_id,
        p.property_name,
        p.property_city,
        p.property_state,
        p.property_region,
        p.property_fund,

        -- ===== Lease FK =====
        t.lease_id,

        -- ===== Audit / DQ =====
        t.notes,
        t.created_at,
        t.modified_at,
        t._stg_birth_date_parse_failed,
        bc._birth_century_imputed

    from tenants t
    left join birth_corrected bc on t.tenant_id  = bc.tenant_id
    left join properties      p  on t.property_id = p.property_id
    left join units           un on t.unit_id     = un.unit_id
    left join leases          l  on t.lease_id    = l.lease_id

)

select * from enriched
