{% macro parse_mixed_date(column_name) %}
{#-
    Parses a TEXT column containing dates in up to 5 inconsistent formats
    observed in the Yardi RAW extract:

      YYYY-MM-DD   (ISO)          e.g. 2023-09-02
      MM/DD/YYYY   (US long)      e.g. 12/19/2023
      MM/DD/YY     (US short)     e.g. 08/02/23
      DD-Mon-YYYY  (Oracle-style) e.g. 09-Dec-2023
      MM-DD-YYYY   (hyphenated)   e.g. 04-16-2023

    Returns DATE or NULL if no pattern matches.

    Each slash/hyphen branch is regex-gated on the exact year width so a
    2-digit year cannot be greedily consumed by the 4-digit format (and
    vice-versa).  Without the gate, TRY_TO_DATE('09/20/24','MM/DD/YYYY')
    silently returns year 0024 instead of 2024, because Snowflake accepts a
    short year against a YYYY token.  REGEXP_LIKE is whole-string anchored in
    Snowflake, so the width guards are mutually exclusive.

    Usage:  {{ parse_mixed_date('DTEFFECTIVE') }} as effective_date
-#}
coalesce(
    try_to_date({{ column_name }}, 'YYYY-MM-DD'),
    try_to_date({{ column_name }}, 'DD-Mon-YYYY'),
    case when regexp_like({{ column_name }}, '\d{1,2}/\d{1,2}/\d{4}')
         then try_to_date({{ column_name }}, 'MM/DD/YYYY') end,
    case when regexp_like({{ column_name }}, '\d{1,2}/\d{1,2}/\d{2}')
         then try_to_date({{ column_name }}, 'MM/DD/YY') end,
    case when regexp_like({{ column_name }}, '\d{1,2}-\d{1,2}-\d{4}')
         then try_to_date({{ column_name }}, 'MM-DD-YYYY') end
)
{% endmacro %}
