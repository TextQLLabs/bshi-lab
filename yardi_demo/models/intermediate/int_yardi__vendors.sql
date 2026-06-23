{{
    config(
        materialized = 'ephemeral',
        schema       = 'intermediate'
    )
}}

{#-
    int_yardi__vendors
    ==================
    Adds conformance and business logic on top of stg_yardi__vendors.

    - Conforms a geographic `region` from state_code via the same
      state->region map used for properties (vendors carry no region
      column of their own; state is the only geographic anchor).
    - Decodes SCATEGORY into a readable category label, retaining the raw
      code for audit.
    - Derives insurance status (Active / Expired / Missing) and 1099
      reportability, plus preferred/active lifecycle status.

    Derived columns:
      - region                    (conformed from state_code)
      - category                  (decoded from category_raw)
      - insurance_status          (Active / Expired / Missing)
      - is_insurance_expired      (expiry in the past)
      - is_1099_reportable        (has a 1099 type and amount > 0)
      - vendor_status             (Preferred / Active / Inactive)
-#}

with vendors as (

    select * from {{ ref('stg_yardi__vendors') }}

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
        v.vendor_id,
        v.vendor_code,
        v.legacy_vendor_id,

        -- ===== Descriptive =====
        v.vendor_name,
        case v.category_raw
            when 'MAINT'     then 'Maintenance'
            when 'UTILITY'   then 'Utility'
            when 'LEGAL'     then 'Legal'
            when 'INSURANCE' then 'Insurance'
            when 'OTHER'     then 'Other'
            else 'unknown_' || coalesce(v.category_raw, 'null')
        end                                          as category,
        v.category_raw,

        -- ===== Address =====
        v.address_line_1,
        v.address_line_2,
        v.city,
        v.state_code,
        v.zip_code,
        coalesce(m.region, 'Unmapped')               as region,

        -- ===== Contact =====
        v.phone,
        v.fax,
        v.email,

        -- ===== Tax / 1099 =====
        v.tax_id_last4,
        v.form_1099_type,
        v.form_1099_amount,
        (
            v.form_1099_type is not null
            and coalesce(v.form_1099_amount, 0) > 0
        )                                            as is_1099_reportable,

        -- ===== Insurance =====
        v.insurance_policy_number,
        v.insurance_expiry_date,
        case
            when v.insurance_policy_number is null
                 or v.insurance_expiry_date is null then 'Missing'
            when v.insurance_expiry_date < current_date() then 'Expired'
            else 'Active'
        end                                          as insurance_status,
        (
            v.insurance_expiry_date is not null
            and v.insurance_expiry_date < current_date()
        )                                            as is_insurance_expired,

        -- ===== Lifecycle =====
        case
            when not v.is_active then 'Inactive'
            when v.is_preferred  then 'Preferred'
            else 'Active'
        end                                          as vendor_status,
        v.is_active,
        v.is_preferred,

        -- ===== Spend =====
        v.ytd_paid,

        -- ===== Free text =====
        v.notes,

        -- ===== Audit & DQ =====
        v.created_at,
        v.modified_at,
        v._stg_insurance_expiry_parse_failed,
        v._stg_insurance_incomplete

    from vendors v
    left join state_region_map m
        on upper(v.state_code) = m.state_code

)

select * from enriched
