{% macro create_prospect_semantic_view() %}
{#-
    create_prospect_semantic_view
    =============================
    Issues the native Snowflake CREATE OR REPLACE SEMANTIC VIEW DDL over
    fct_prospects.  Invoked as a post_hook on the sem_prospect_funnel control
    model so the object is (re)created on every dbt run, AFTER fct_prospects
    is built.  The DDL lives here so it is fully version-controlled in the dbt
    repo rather than applied manually in Snowflake.

    Target object: {database}.MARTS.SEM_PROSPECT_FUNNEL
    Grain of base table: one row per prospect (guest card).
-#}

{% set fq_fact   = ref('fct_prospects') %}
{% set view_name = (target.database ~ '.MARTS.SEM_PROSPECT_FUNNEL') %}

create or replace semantic view {{ view_name }}

  tables (
    prospects as {{ fq_fact }}
      primary key (prospect_id)
      with synonyms ('leads', 'guest cards', 'leasing funnel')
      comment = 'Leasing-funnel guest cards, one row per prospect'
  )

  facts (
    prospects.toured              as (case when reached_tour then 1 else 0 end),
    prospects.applied             as (case when reached_application then 1 else 0 end),
    prospects.approved            as (case when reached_approval then 1 else 0 end),
    prospects.leased              as (case when reached_lease then 1 else 0 end),
    prospects.days_to_apply_fact  as days_to_apply,
    prospects.days_to_movein_fact as days_to_movein,
    prospects.desired_rent_fact   as desired_rent
  )

  dimensions (
    prospects.prospect_status   as prospect_status
      with synonyms ('funnel stage','stage')
      comment = 'new/contacted/toured/applied/approved/denied/waitlist/leased',
    prospects.lead_source       as lead_source
      with synonyms ('marketing channel','source'),
    prospects.desired_bedrooms  as desired_bedrooms,
    prospects.leasing_agent     as leasing_agent,
    prospects.property_name     as property_name,
    prospects.property_region   as property_region with synonyms ('region'),
    prospects.property_fund     as property_fund with synonyms ('fund'),
    prospects.contact_date      as contact_date,
    prospects.contact_month     as contact_month
  )

  metrics (
    prospects.total_prospects AS COUNT(prospects.prospect_id)
      comment = 'Count of prospects (leads)',
    prospects.leased_prospects AS SUM(prospects.leased)
      comment = 'Count of converted prospects',
    prospects.tour_rate AS SUM(prospects.toured) / NULLIF(COUNT(prospects.prospect_id), 0)
      comment = 'Share of prospects that toured',
    prospects.application_rate AS SUM(prospects.applied) / NULLIF(COUNT(prospects.prospect_id), 0)
      comment = 'Share of prospects that applied',
    prospects.approval_rate AS SUM(prospects.approved) / NULLIF(SUM(prospects.applied), 0)
      comment = 'Approved share of applicants',
    prospects.lead_to_lease_conversion AS SUM(prospects.leased) / NULLIF(COUNT(prospects.prospect_id), 0)
      comment = 'Overall lead-to-lease conversion',
    prospects.avg_days_to_apply AS SUM(prospects.days_to_apply_fact) / NULLIF(SUM(prospects.applied), 0)
      comment = 'Average days from contact to application',
    prospects.avg_days_to_movein AS SUM(prospects.days_to_movein_fact) / NULLIF(SUM(prospects.leased), 0)
      comment = 'Average days from application to move-in',
    prospects.avg_desired_rent AS AVG(prospects.desired_rent_fact)
      comment = 'Average desired monthly rent'
  )

  comment = 'Prospect leasing funnel semantic view (dbt-managed; built over fct_prospects)'

{% endmacro %}
