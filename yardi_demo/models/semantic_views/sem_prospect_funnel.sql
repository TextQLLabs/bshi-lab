{{
    config(
        materialized = 'table',
        schema       = 'marts',
        tags         = ['semantic_view'],
        post_hook    = [ "{{ create_prospect_semantic_view() }}" ]
    )
}}

{#-
    sem_prospect_funnel  (control model)
    ====================================
    dbt does NOT natively materialize a Snowflake SEMANTIC VIEW, so this model
    is the version-controlled control point for the native object:

      - This SELECT builds a tiny one-row "anchor" table whose ONLY job is to
        (a) create a dependency on fct_prospects via ref(), so dbt schedules
            the semantic view AFTER the fact table is built, and
        (b) give the post_hook a model to attach to.
      - The post_hook calls the create_prospect_semantic_view() macro, which
        runs CREATE OR REPLACE SEMANTIC VIEW ... over fct_prospects.

    Net effect: `dbt run --select sem_prospect_funnel` (or a full run) creates
    / refreshes the native Snowflake SEMANTIC VIEW
    YARDI.MARTS.SEM_PROSPECT_FUNNEL, with the DDL fully controlled from this
    dbt repo. Cortex Analyst / SHOW SEMANTIC VIEWS then see the object.
-#}

select
    '{{ ref('fct_prospects') }}'      as built_over,
    count(*)                          as prospect_rows,
    current_timestamp()               as _dbt_built_at
from {{ ref('fct_prospects') }}
