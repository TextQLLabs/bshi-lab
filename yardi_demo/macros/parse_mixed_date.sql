{% macro parse_mixed_date(column_name) %}
{#-
    Parses a TEXT column containing dates in the 5 inconsistent formats
    observed in the Yardi RAW extract:

      YYYY-MM-DD   (ISO)          e.g. 2023-09-02
      DD-Mon-YYYY  (Oracle-style) e.g. 09-Dec-2023
      MM-DD-YYYY   (hyphenated)   e.g. 04-16-2023
      MM/DD/YYYY   (US long)      e.g. 12/19/2023
      MM/DD/YY     (US short)     e.g. 08/02/23

    Returns DATE, or NULL if no pattern matches.

    IMPORTANT -- why this dispatches on shape instead of coalescing
    try_to_date() attempts:

    The previous coalesce() implementation silently mis-parsed the MM/DD/YY
    format. try_to_date('01/01/22', 'MM/DD/YYYY') does NOT fail; Snowflake
    accepts the 2-digit year literally and returns 0022-01-01 -- a date two
    millennia off. Because it returned a non-NULL value, the downstream
    _parse_failed data-quality flag never fired, so the corruption was
    invisible. Measured against RAW.TRANS.DTEFFECTIVE, all 426 rows of the
    MM/DD/YY format were affected.

    Matching each format on its literal shape first makes the century rule
    explicit and removes the parser's guesswork. Observed 2-digit years in
    the source span 22-24, so they are pinned to the 2000s.
-#}
case
    when {{ column_name }} is null or trim({{ column_name }}) = '' then null

    when {{ column_name }} rlike '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
        then try_to_date({{ column_name }}, 'YYYY-MM-DD')

    when {{ column_name }} rlike '^[0-9]{2}-[A-Za-z]{3}-[0-9]{4}$'
        then try_to_date({{ column_name }}, 'DD-MON-YYYY')

    when {{ column_name }} rlike '^[0-9]{2}-[0-9]{2}-[0-9]{4}$'
        then try_to_date({{ column_name }}, 'MM-DD-YYYY')

    when {{ column_name }} rlike '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
        then try_to_date({{ column_name }}, 'MM/DD/YYYY')

    when {{ column_name }} rlike '^[0-9]{2}/[0-9]{2}/[0-9]{2}$'
        then try_to_date(
                 '20' || split_part({{ column_name }}, '/', 3) || '-'
                      || split_part({{ column_name }}, '/', 1) || '-'
                      || split_part({{ column_name }}, '/', 2),
                 'YYYY-MM-DD')
end
{% endmacro %}
