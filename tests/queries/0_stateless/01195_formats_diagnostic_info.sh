#!/usr/bin/env bash
# shellcheck disable=SC2206

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

PARSER=(${CLICKHOUSE_LOCAL} --query 'SELECT t, s, d FROM table' --structure 't DateTime, s String, d Decimal64(10)' --input-format CSV --input_format_csv_detect_header 0)
echo '2020-04-21 12:34:56, "Hello", 12345678' | "${PARSER[@]}"  2>&1| grep "ERROR" || echo "CSV"
echo '2020-04-21 12:34:56, "Hello", 123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '2020-04-21 12:34:567, "Hello", 123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
#echo '2020-04-21, "Hello", 123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"    # DateTime parsing is unsafe, it produces unexpected result ("Hello" is parsed as time)
echo '2020-04-21 12:34:56, "Hello", 12345678,1' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '2020-04-21 12:34:56,,123Hello' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56, "Hello", 12345678\n' | "${PARSER[@]}" 2>&1| grep "ERROR"

PARSER=(${CLICKHOUSE_LOCAL} --query 'SELECT t, s, d FROM table' --structure 't DateTime, s String, d Decimal64(10)' --input-format CustomSeparatedIgnoreSpaces --format_custom_escaping_rule CSV --format_custom_field_delimiter ',' --format_custom_row_after_delimiter "" --input_format_custom_detect_header 0)
echo '2020-04-21 12:34:56, "Hello", 12345678' | "${PARSER[@]}"  2>&1| grep "ERROR" || echo -e  "\nCustomSeparatedIgnoreSpaces"
echo '2020-04-21 12:34:56, "Hello", 123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '2020-04-21 12:34:567, "Hello", 123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '2020-04-21 12:34:56, "Hello", 12345678,1' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '2020-04-21 12:34:56,,123Hello' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56, "Hello", 12345678\n\n\n\n   ' | "${PARSER[@]}" 2>&1| grep "ERROR" || echo "OK"

PARSER=(${CLICKHOUSE_LOCAL} --input_format_null_as_default 0 --query 'SELECT t, s, d FROM table' --structure 't DateTime, s String, d Decimal64(10)' --input-format TSV --input_format_tsv_detect_header 0)
echo -e '2020-04-21 12:34:56\tHello\t12345678' | "${PARSER[@]}"  2>&1| grep "ERROR" || echo -e "\nTSV"
echo -e '2020-04-21 12:34:56\tHello\t123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:567\tHello\t123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56\tHello\t12345678\t1' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56\t\t123Hello' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56\tHello\t12345678\n' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '\N\tHello\t12345678' | "${PARSER[@]}" 2>&1| grep -o "Unexpected NULL value"

PARSER=(${CLICKHOUSE_LOCAL} --query 'SELECT t, s, d FROM table' --structure 't DateTime, s String, d Decimal64(10)' --input-format CustomSeparated --input_format_custom_detect_header 0)
echo -e '2020-04-21 12:34:56\tHello\t12345678' | "${PARSER[@]}"  2>&1| grep "ERROR" || echo -e "\nCustomSeparated"
echo -e '2020-04-21 12:34:56\tHello\t123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:567\tHello\t123456789' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56\tHello\t12345678\t1' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '2020-04-21 12:34:56\t\t123Hello' | "${PARSER[@]}" 2>&1| grep "ERROR"

PARSER=(${CLICKHOUSE_LOCAL} --query 'SELECT t, s, d FROM table' --structure 't DateTime, s String, d Decimal64(10)' --input-format JSONCompactEachRow)
echo '["2020-04-21 12:34:56", "Hello", 12345678]' | "${PARSER[@]}"  2>&1| grep "ERROR" || echo "JSONCompactEachRow"
echo '["2020-04-21 12:34:56", "Hello", 123456789]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '["2020-04-21 12:34:567", "Hello", 123456789]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '["2020-04-21 12:34:56"7, "Hello", 123456789]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '["2020-04-21 12:34:56", "Hello", 12345678,1]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo '["2020-04-21 12:34:56",,123Hello]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello", 12345678\n]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '"2020-04-21 12:34:56", "Hello", 12345678]' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello", 12345678;' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello", 12345678' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello", 12345678\n' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello"; 12345678\n' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello"\n' | "${PARSER[@]}" 2>&1| grep "ERROR"
echo -e '["2020-04-21 12:34:56", "Hello"]' | "${PARSER[@]}" 2>&1| grep "ERROR"
