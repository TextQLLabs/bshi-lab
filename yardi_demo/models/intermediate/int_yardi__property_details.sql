{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__property_details
    ===========================
    Enriches the staged property with a CONFORMED region derived from the
    physical state, valuation / hold-period business logic, and unit-count
    reconciliation.  Joins against staging models so upstream cleaning is
    inherited.

    Business logic added:
      - region                    (conformed region derived from state)
      - _int_region_mismatch      (conformed region != raw region_reported)
      - value_gain / value_gain_pct   (market value vs purchase price)
      - market_value_per_unit
      - hold_period_years         (acquired -> disposed or current date)
      - is_disposed
      - _int_active_disposed_conflict  (is_active vs disposal state disagree)
      - actual_unit_count / _int_unit_count_mismatch (observability only)
      - property_size_band
-#}

with properties as (

    select * from {{ ref('stg_yardi__properties') }}

),

unit_counts as (

    select
        property_id,
        count(*) as actual_unit_count
    from {{ ref('stg_yardi__units') }}
    group by property_id

),

enriched as (

    select
        -- ===== Property core =====
        p.property_id,
        p.property_code,
        p.property_name,
        p.property_type,
        p.property_type_code,

        -- ===== Address =====
        p.address_line_1,
        p.address_line_2,
        p.city,
        p.state,
        p.zip_code,
        p.county,

        -- ===== Conformed region (derived from state) =====
        case p.state
            when 'NY' then 'Northeast' when 'PA' then 'Northeast'
            when 'MA' then 'Northeast' when 'NJ' then 'Northeast'
            when 'CT' then 'Northeast' when 'RI' then 'Northeast'
            when 'VT' then 'Northeast' when 'NH' then 'Northeast'
            when 'ME' then 'Northeast' when 'MD' then 'Northeast'
            when 'DE' then 'Northeast' when 'DC' then 'Northeast'
            when 'GA' then 'Southeast' when 'FL' then 'Southeast'
            when 'TN' then 'Southeast' when 'NC' then 'Southeast'
            when 'SC' then 'Southeast' when 'VA' then 'Southeast'
            when 'WV' then 'Southeast' when 'KY' then 'Southeast'
            when 'AL' then 'Southeast' when 'MS' then 'Southeast'
            when 'AR' then 'Southeast' when 'LA' then 'Southeast'
            when 'IL' then 'Midwest'   when 'OH' then 'Midwest'
            when 'MI' then 'Midwest'   when 'IN' then 'Midwest'
            when 'WI' then 'Midwest'   when 'MO' then 'Midwest'
            when 'IA' then 'Midwest'   when 'KS' then 'Midwest'
            when 'NE' then 'Midwest'   when 'ND' then 'Midwest'
            when 'SD' then 'Midwest'   when 'MN' then 'Midwest'
            when 'TX' then 'Southwest' when 'AZ' then 'Southwest'
            when 'CO' then 'Southwest' when 'NM' then 'Southwest'
            when 'NV' then 'Southwest' when 'UT' then 'Southwest'
            when 'OK' then 'Southwest'
            when 'CA' then 'West Coast' when 'HI' then 'West Coast'
            when 'WA' then 'Pacific NW' when 'OR' then 'Pacific NW'
            when 'ID' then 'Pacific NW' when 'AK' then 'Pacific NW'
            else 'Unmapped'
        end                                             as region,
        p.region_reported,
        p.legacy_region_code,

        -- ===== Ownership =====
        p.owner_id,
        p.owner_name,
        p.owner_tax_id_masked,

        -- ===== Size =====
        p.reported_total_units,
        uc.actual_unit_count,
        case
            when p.reported_total_units < 50  then 'small'
            when p.reported_total_units < 150 then 'medium'
            when p.reported_total_units < 250 then 'large'
            else 'very_large'
        end                                             as property_size_band,

        -- ===== Economics =====
        p.market_value,
        p.purchase_price,
        (p.market_value - p.purchase_price)             as value_gain,
        case
            when p.purchase_price > 0
            then round((p.market_value - p.purchase_price) / p.purchase_price, 4)
        end                                             as value_gain_pct,
        case
            when p.reported_total_units > 0
            then round(p.market_value / p.reported_total_units, 2)
        end                                             as market_value_per_unit,

        -- ===== Lifecycle =====
        p.acquired_date,
        p.disposed_date,
        (p.disposed_date is not null)                   as is_disposed,
        round(
            datediff('day', p.acquired_date,
                     coalesce(p.disposed_date, current_date())) / 365.0, 2
        )                                               as hold_period_years,
        p.is_active,
        p.is_tax_exempt,
        p.fund,

        -- ===== Free text / audit =====
        p.notes,
        p.legacy_property_id,
        p.created_at,
        p.modified_at,
        p.modified_by,

        -- ===== Data-quality observability =====
        p._stg_acquired_date_parse_failed,
        p._stg_disposed_date_parse_failed,
        (
            case p.state
                when 'NY' then 'Northeast' when 'PA' then 'Northeast'
                when 'MA' then 'Northeast' when 'NJ' then 'Northeast'
                when 'CT' then 'Northeast' when 'RI' then 'Northeast'
                when 'VT' then 'Northeast' when 'NH' then 'Northeast'
                when 'ME' then 'Northeast' when 'MD' then 'Northeast'
                when 'DE' then 'Northeast' when 'DC' then 'Northeast'
                when 'GA' then 'Southeast' when 'FL' then 'Southeast'
                when 'TN' then 'Southeast' when 'NC' then 'Southeast'
                when 'SC' then 'Southeast' when 'VA' then 'Southeast'
                when 'WV' then 'Southeast' when 'KY' then 'Southeast'
                when 'AL' then 'Southeast' when 'MS' then 'Southeast'
                when 'AR' then 'Southeast' when 'LA' then 'Southeast'
                when 'IL' then 'Midwest'   when 'OH' then 'Midwest'
                when 'MI' then 'Midwest'   when 'IN' then 'Midwest'
                when 'WI' then 'Midwest'   when 'MO' then 'Midwest'
                when 'IA' then 'Midwest'   when 'KS' then 'Midwest'
                when 'NE' then 'Midwest'   when 'ND' then 'Midwest'
                when 'SD' then 'Midwest'   when 'MN' then 'Midwest'
                when 'TX' then 'Southwest' when 'AZ' then 'Southwest'
                when 'CO' then 'Southwest' when 'NM' then 'Southwest'
                when 'NV' then 'Southwest' when 'UT' then 'Southwest'
                when 'OK' then 'Southwest'
                when 'CA' then 'West Coast' when 'HI' then 'West Coast'
                when 'WA' then 'Pacific NW' when 'OR' then 'Pacific NW'
                when 'ID' then 'Pacific NW' when 'AK' then 'Pacific NW'
                else 'Unmapped'
            end <> p.region_reported
        )                                               as _int_region_mismatch,
        (
            (p.is_active and p.disposed_date is not null)
            or (not p.is_active and p.disposed_date is null)
        )                                               as _int_active_disposed_conflict,
        (p.reported_total_units <> coalesce(uc.actual_unit_count, 0)) as _int_unit_count_mismatch

    from properties p
    left join unit_counts uc on p.property_id = uc.property_id

)

select * from enriched
