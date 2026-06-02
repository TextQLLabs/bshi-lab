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
    Usage:  {{ parse_mixed_date('DTEFFECTIVE') }} as effective_date
-#}
coalesce(
    try_to_date({{ column_name }}, 'YYYY-MM-DD'),
    try_to_date({{ column_name }}, 'MM/DD/YYYY'),
    try_to_date({{ column_name }}, 'MM/DD/YY'),
    try_to_date({{ column_name }}, 'DD-Mon-YYYY'),
    try_to_date({{ column_name }}, 'MM-DD-YYYY')
)
{% endmacro %}
