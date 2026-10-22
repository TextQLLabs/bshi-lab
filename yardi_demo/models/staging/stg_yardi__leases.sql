{{
  config(materialized='view')
}}

-- Conformed lease staging model.
--
-- Repairs five defects in RAW.LEASE that silently corrupt downstream leasing
-- and retention analysis:
--   1. SUNITCODE is overwritten with a numeric id on every terminated lease,
--      so the authoritative unit code is taken from UNIT.SCODE.
--   2. Lease state is evaluated against the warehouse data horizon rather than
--      the wall clock, because the extract ends 2024-12-28.
--   3. Month-to-month leases carry a NULL end date BY DESIGN and are modelled
--      as their own state, never as an expiry and never as a data error.
--   4. DTNOTICE is unrelated to actual departures and is quarantined behind a
--      usability flag instead of being exposed as a usable date.
--   5. BRENEWED and HPRIORLEASE disagree, so renewal lineage is made explicit.

with source as (

    select * from {{ source('yardi', 'LEASE') }}

),

units as (

    select
        HMY   as unit_id,
        SCODE as unit_code
    from {{ source('yardi', 'UNIT') }}

),

horizon as (

    -- The extract has no wall-clock "today". Derive it from the journal.
    select max(DTTRANSACTION) as data_as_of
    from {{ source('yardi', 'TRANS') }}

),

renamed as (

    select
        s.HMY                                       as lease_id,
        s.HPROPERTY                                 as property_id,
        s.HUNIT                                     as unit_id,
        s.HTENANT                                   as tenant_id,
        s.SCODE                                     as lease_code,
        s.STYPE                                     as lease_type_code,

        case when s.STYPE = 'MTM'
             then 'month_to_month'
             else 'fixed_term'
        end                                         as lease_term_type,

        h.data_as_of                                as data_as_of,

        s.DTLEASEFROM::date                         as lease_start_date,
        s.DTLEASETO::date                           as lease_end_date,
        s.DTMOVEIN::date                            as move_in_date,
        s.DTMOVEOUT::date                           as move_out_date,

        case
            when s.DTMOVEOUT is not null     then 'terminated'
            when s.STYPE = 'MTM'             then 'open_month_to_month'
            when s.DTLEASETO >= h.data_as_of then 'active_fixed_term'
            else 'expired_no_move_out'
        end                                         as lease_state,

        -- Authoritative unit code. NEVER use s.SUNITCODE.
        u.unit_code                                 as unit_code,

        s.MRENT                                     as monthly_rent,
        s.MRENT * 12                                as annualized_rent,
        nullif(s.MCONCESSION, 0)                    as concession_amount,
        (s.MRENT * 12) - coalesce(s.MCONCESSION, 0) as annualized_rent_net_concession,

        coalesce(nullif(trim(s.STERMREASON), ''), 'not_recorded') as termination_reason,

        case
            when s.BRENEWED = 1 and coalesce(s.HPRIORLEASE, 0) <> 0 then 'confirmed_renewal'
            when s.BRENEWED = 1                                     then 'flagged_no_lineage'
            when coalesce(s.HPRIORLEASE, 0) <> 0                    then 'lineage_not_flagged'
            else 'new_lease'
        end                                         as renewal_state,

        nullif(s.HPRIORLEASE, 0)                    as prior_lease_id,

        -- Quarantined: notice dates do not relate to actual departures.
        s.DTNOTICE::date                            as _stg_notice_date_quarantined,

        -- DQ flags -------------------------------------------------------
        case when s.SUNITCODE <> u.unit_code
             then true else false end               as _stg_unit_code_corrupt_in_source,

        case when s.DTMOVEOUT is null
              and s.STYPE <> 'MTM'
              and s.DTLEASETO < h.data_as_of
             then true else false end               as _stg_is_unresolved_expiry,

        case when s.DTMOVEOUT is not null
              and (s.STERMREASON is null or trim(s.STERMREASON) = '')
             then true else false end               as _stg_termination_reason_missing,

        case when s.DTMOVEOUT is not null
              and s.DTNOTICE is not null
              and s.DTNOTICE <= s.DTMOVEOUT
             then true else false end               as _stg_notice_date_usable,

        case when coalesce(s.MCONCESSION, 0) > 0
              and (s.SCONCESSIONDESC is null or trim(s.SCONCESSIONDESC) = '')
             then true else false end               as _stg_concession_undocumented

    from source s
    left join units u on u.unit_id = s.HUNIT
    cross join horizon h

)

select * from renamed
