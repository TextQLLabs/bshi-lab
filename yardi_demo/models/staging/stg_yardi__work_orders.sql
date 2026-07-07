{{
    config(
        materialized = 'view',
        schema       = 'staging'
    )
}}

{#-
    stg_yardi__work_orders
    ======================
    Cleans the RAW.WORKORDER table (one row per maintenance work order):
      - Renames Hungarian-notation columns to business-friendly names
      - Casts DTSCHEDULED from TEXT to DATE (mixed formats via macro);
        DTREQUESTED and DTCOMPLETED are already native DATE in the source
      - Replaces magic-number ISTATUS with human-readable work_order_status
        (0=open, 1=in_progress, 2=complete, 3=cancelled, 4=on_hold).  The
        co-located SSTATUSDESC text column agrees with the code, but the
        numeric ISTATUS is the authoritative source.
      - Derives priority_label from the numeric IPRIORITY (1=low, 2=medium,
        3=high, 4=emergency).  The text SPRIORITY column is NOT trusted: it
        carries inconsistent free-text variants (low/LOW/Low, EMER/URGENT/
        EMERGENCY) for the same numeric code.
      - Nullifies zero-value HVENDOR (means "self-performed, no vendor");
        57 of 200 work orders have no vendor.
      - Casts the 0/1 BPERMISSIONTOENTER flag to boolean
      - Drops 3 denormalized text columns (SPROPNAME, SUNITCODE, STENANTNAME)
        -- resolved via joins in the intermediate layer
      - Adds _stg_scheduled_date_parse_failed flag for observability
-#}

with source as (

    select * from {{ source('yardi', 'WORKORDER') }}

),

renamed as (

    select
        -- ===== Primary key =====
        hmy                                          as work_order_id,

        -- ===== Foreign keys =====
        hproperty                                    as property_id,
        hunit                                        as unit_id,
        nullif(htenant, 0)                           as tenant_id,
        nullif(hvendor, 0)                           as vendor_id,

        -- ===== Identifiers =====
        scode                                        as work_order_code,
        scategory                                    as category,

        -- ===== Priority (derived from numeric IPRIORITY) =====
        case ipriority
            when 1 then 'low'
            when 2 then 'medium'
            when 3 then 'high'
            when 4 then 'emergency'
            else 'unknown_' || cast(ipriority as varchar)
        end                                          as priority_label,
        ipriority                                    as priority_code,

        -- ===== Status (derived from numeric ISTATUS) =====
        case istatus
            when 0 then 'open'
            when 1 then 'in_progress'
            when 2 then 'complete'
            when 3 then 'cancelled'
            when 4 then 'on_hold'
            else 'unknown_' || cast(istatus as varchar)
        end                                          as work_order_status,
        istatus                                      as work_order_status_code,

        -- ===== Description / resolution =====
        sdesc                                        as work_order_description,
        sresolution                                  as resolution_notes,
        sassignedto                                  as assigned_to,
        sentrynotes                                  as entry_notes,

        -- ===== Dates =====
        dtrequested                                  as requested_date,
        {{ parse_mixed_date('dtscheduled') }}        as scheduled_date,
        dtcompleted                                  as completed_date,

        -- ===== Costs =====
        mlaborcost                                   as labor_cost,
        mmaterialcost                                as material_cost,
        mtotalcost                                   as total_cost,

        -- ===== Flags =====
        (bpermissiontoenter = 1)                     as has_permission_to_enter,

        -- ===== Audit =====
        dtcreated                                    as created_at,
        dtmodified                                   as modified_at,

        -- ===== Data-quality observability =====
        (
            dtscheduled is not null
            and dtscheduled != ''
            and {{ parse_mixed_date('dtscheduled') }} is null
        )                                            as _stg_scheduled_date_parse_failed

    from source

)

select * from renamed
