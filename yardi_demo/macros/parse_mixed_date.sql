{% macro parse_mixed_date(column_name) %}
{#-
    Parses a TEXT column containing dates in up to 5 inconsistent formats
    observed in the Yardi RAW extract:

      YYYY-MM-DD   (ISO)          e.g. 2023-09-02
      MM/DD/YY     (US short)     e.g. 08/02/23
      MM/DD/YYYY   (US long)      e.g. 12/19/2023
      DD-Mon-YYYY  (Oracle-style) e.g. 09-Dec-2023
      MM-DD-YYYY   (hyphenated)   e.g. 04-16-2023

    Returns DATE or NULL if no pattern matches.

    ORDERING NOTE (bug fix 2026-08):
      'MM/DD/YY' MUST be tried before 'MM/DD/YYYY'.  Snowflake's TRY_TO_DATE
      greedily accepts a 2-digit-year string (e.g. '01/21/08') into the
      4-digit 'YYYY' slot, yielding year 0008 instead of 2008.  The 2-digit
      format correctly returns NULL for genuine 4-digit-year strings, so
      trying it first is safe and prevents silent year corruption.
      (Previously mis-parsed 426/2000 TRANS.DTEFFECTIVE and 35/240
      UNIT.DTLASTINSPECTION rows to years < 1900.)

    Usage:  {{ parse_mixed_date('DTEFFECTIVE') }} as effective_date
-#}
coalesce(
    try_to_date({{ column_name }}, 'YYYY-MM-DD'),
    try_to_date({{ column_name }}, 'MM/DD/YY'),
    try_to_date({{ column_name }}, 'MM/DD/YYYY'),
    try_to_date({{ column_name }}, 'DD-Mon-YYYY'),
    try_to_date({{ column_name }}, 'MM-DD-YYYY')
)
{% endmacro %}
