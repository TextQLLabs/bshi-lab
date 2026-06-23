{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__prospects
    ====================
    Cleans the RAW.PROSPECT table (leasing funnel / guest card):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTSHOWDATE from TEXT to DATE (5 mixed formats via macro)
      - Replaces magic-number ISTATUS (0-7) with a human-readable
        leasing-funnel stage, decoded from the status/date cross-tab
      - Nullifies zero-value HUNIT FK (54 rows) meaning "no unit assigned yet"
      - Normalizes SSOURCE / SDESIREDBEDS casing and blanks
      - Drops denormalized SPROPNAME (resolved via join in intermediate)
      - Adds _stg_show_date_parse_failed flag for observability
-#}

with source as (

    select * from {{ source('yardi', 'PROSPECT') }}

),

renamed as (

    select
        -- ===== Primary key =====
        hmy                                         as prospect_id,

        -- ===== Foreign keys =====
        hproperty                                   as property_id,
        nullif(hunit, 0)                            as unit_id,

        -- ===== Prospect attributes =====
        sfirstname                                  as first_name,
        slastname                                   as last_name,
        trim(sfirstname || ' ' || slastname)        as full_name,
        sphone                                      as phone,
        semail                                      as email,
        nullif(upper(trim(ssource)), '')            as lead_source,
        sagent                                      as leasing_agent,
        nullif(upper(trim(sdesiredbeds)), '')       as desired_bedrooms,
        mdesiredrent                                as desired_rent,

        -- ===== Funnel dates =====
        dtcontact                                   as contact_date,
        {{ parse_mixed_date('dtshowdate') }}        as show_date,
        dtapplied                                   as applied_date,
        dtapproved                                  as approved_date,
        dtdenied                                    as denied_date,
        dtmovein                                    as move_in_date,

        -- ===== Status =====
        istatus                                     as prospect_status_code,
        case istatus
            when 0 then 'new'
            when 1 then 'contacted'
            when 2 then 'toured'
            when 3 then 'applied'
            when 4 then 'approved'
            when 5 then 'denied'
            when 6 then 'waitlist'
            when 7 then 'leased'
            else 'unknown_' || cast(istatus as varchar)
        end                                         as prospect_status,

        snotes                                      as notes,

        -- ===== Audit =====
        dtcreated                                   as created_at,
        dtmodified                                  as modified_at,

        -- ===== Data-quality observability =====
        (
            dtshowdate is not null
            and dtshowdate != ''
            and {{ parse_mixed_date('dtshowdate') }} is null
        )                                           as _stg_show_date_parse_failed

    from source

)

select * from renamed
