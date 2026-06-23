{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__properties
    =====================
    Adds conformance and business logic on top of stg_yardi__properties.

    The RAW PROPERTY table carries THREE disagreeing region signals:
      - SREGION          (free text, frequently wrong: PA -> "West Coast")
      - LEGACY_REGION_CD (2-char code, NULL for 5/20, also unreliable)
      - SSTATE           (the only trustworthy geographic anchor)

    Resolution: derive an authoritative `region` from `state_code` via a
    state->region mapping, keep the raw signals for audit, and emit a
    `region_signals_conflict` flag when the trusted region disagrees with
    the source-provided SREGION.

    Derived columns:
      - region                    (conformed, authoritative)
      - region_signals_conflict   (region != region_raw)
      - ownership_status          (Active / Disposed / Inactive)
      - hold_period_years         (disposed_date or today - acquired_date)
      - value_appreciation        (market_value - purchase_price)
      - value_appreciation_pct    (appreciation / purchase_price)
      - market_value_per_unit     (market_value / total_units)
-#}

with properties as (

    select * from {{ ref('stg_yardi__properties') }}

),

state_region_map as (

    select column1 as state_code, column2 as region
    from (
        values
            ('CT','Northeast'),('ME','Northeast'),('MA','Northeast'),
            ('NH','Northeast'),('NJ','Northeast'),('NY','Northeast'),
            ('PA','Northeast'),('RI','Northeast'),('VT','Northeast'),
            ('IL','Midwest'),('IN','Midwest'),('IA','Midwest'),
            ('KS','Midwest'),('MI','Midwest'),('MN','Midwest'),
            ('MO','Midwest'),('NE','Midwest'),('ND','Midwest'),
            ('OH','Midwest'),('SD','Midwest'),('WI','Midwest'),
            ('AL','Southeast'),('FL','Southeast'),('GA','Southeast'),
            ('KY','Southeast'),('MS','Southeast'),('NC','Southeast'),
            ('SC','Southeast'),('TN','Southeast'),('VA','Southeast'),
            ('WV','Southeast'),('AR','Southeast'),('LA','Southeast'),
            ('AZ','Southwest'),('NM','Southwest'),('OK','Southwest'),
            ('TX','Southwest'),
            ('CA','West Coast'),('NV','West Coast'),('HI','West Coast'),
            ('CO','West'),('ID','West'),('MT','West'),('UT','West'),
            ('WY','West'),('AK','West'),
            ('OR','Pacific NW'),('WA','Pacific NW')
    )

),

enriched as (

    select
        -- ===== Identifiers =====
        p.property_id,
        p.property_code,
        p.legacy_property_id,

        -- ===== Descriptive =====
        p.property_name,
        p.property_type,
        p.property_type_code,
        p.fund,
        p.total_units,

        -- ===== Address =====
        p.address_line_1,
        p.address_line_2,
        p.city,
        p.state_code,
        p.zip_code,
        p.county,

        -- ===== Region conformance =====
        coalesce(m.region, 'Unmapped')               as region,
        p.region_raw,
        p.legacy_region_code,
        (
            m.region is not null
            and p.region_raw is not null
            and m.region != p.region_raw
        )                                            as region_signals_conflict,

        -- ===== Management & ownership =====
        p.manager_name,
        p.manager_email,
        p.owner_name,
        p.owner_tax_id_last4,
        p.owner_id,

        -- ===== Dates =====
        p.acquired_date,
        p.disposed_date,

        -- ===== Lifecycle =====
        case
            when p.disposed_date is not null then 'Disposed'
            when p.is_active                 then 'Active'
            else 'Inactive'
        end                                          as ownership_status,
        datediff(
            'day',
            p.acquired_date,
            coalesce(p.disposed_date, current_date())
        ) / 365.25                                   as hold_period_years,

        -- ===== Valuation =====
        p.market_value,
        p.purchase_price,
        (p.market_value - p.purchase_price)          as value_appreciation,
        case
            when p.purchase_price > 0
            then (p.market_value - p.purchase_price) / p.purchase_price
        end                                          as value_appreciation_pct,
        case
            when p.total_units > 0
            then p.market_value / p.total_units
        end                                          as market_value_per_unit,

        -- ===== Flags =====
        p.is_active,
        p.is_tax_exempt,

        -- ===== Free text =====
        p.notes,

        -- ===== Audit & DQ =====
        p.created_at,
        p.modified_at,
        p.modified_by,
        p._stg_acquired_date_parse_failed,
        p._stg_disposed_date_parse_failed,
        p._stg_county_missing

    from properties p
    left join state_region_map m
        on upper(p.state_code) = m.state_code

)

select * from enriched
