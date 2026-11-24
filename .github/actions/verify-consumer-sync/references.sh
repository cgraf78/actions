# shellcheck shell=bash

actions_yq=yq

actions_yq_available() {
  local answer
  answer=$(printf 'uses: value\n' | "$actions_yq" -N -r \
    'explode(.) | .uses | [line, column, style, .] | join("\t")' 2>/dev/null) ||
    return 1
  [[ "$answer" == $'1\t7\t\tvalue' ]]
}

# Use the parser's scalar values for policy and its source positions to change
# only the bytes of a use site. Comments, shell strings and unrelated YAML
# fields can contain dependency examples but cannot select Actions code.
read_actions_references() {
  local file=$1 label=$2
  "$actions_yq" -N -r -p yaml -o yaml '
    explode(.) | (.jobs[].uses, .jobs[].steps[].uses, .runs.steps[].uses)
    | select(tag == "!!str")
    | select(test("(?i)^cgraf78/actions/"))
    | [line, column, ((style | select(. != "")) // "plain"),
       test("[[:cntrl:]]"), sub("[[:cntrl:]]"; "?")]
    | join("\t")
  ' "$file" || {
    printf 'cannot parse Actions references in %s\n' "$label" >&2
    return 1
  }
}

valid_actions_ref() {
  local value=$1 controls=$2 style=$3 label=$4 row=$5
  if [[ "$controls" == true || "$value" != ?*@?* ||
    ("$style" == plain && "${value#*@}" == *,*) ]]; then
    printf 'invalid Actions reference spelling in %s:%s\n' "$label" "$row" >&2
    return 1
  fi
}

# The parser reports one-based Unicode columns. Translate to a byte offset
# independently of the maintainer or runner's locale.
yaml_byte_offset() {
  local LC_ALL=C
  local line=$1 column=$2 offset=0
  while [[ "$column" -gt 1 && "$offset" -lt "${#line}" ]]; do
    offset=$((offset + 1))
    while [[ "${line:offset:1}" == [$'\200'-$'\277'] ]]; do
      offset=$((offset + 1))
    done
    column=$((column - 1))
  done
  printf '%d\n' "$offset"
}

# Consume reference records sorted by original source position. Block scalar
# values for a literal use occupy the next line. Require an exact span for
# rewrites, so a stale alias or escape cannot change unrelated YAML.
render_actions_references() {
  local LC_ALL=C
  local label=$2 target=$3
  local row column style controls value raw wanted offset
  local line newline line_number=0 cursor rendered

  IFS=$'\t' read -r row column style controls value <&3 || return 1
  while :; do
    if IFS= read -r line; then
      newline=$'\n'
    elif [[ -n "$line" ]]; then
      newline=
    else
      break
    fi
    line_number=$((line_number + 1))
    cursor=0
    rendered=
    while [[ -n "$row" ]]; do
      case "$style" in
        folded | literal) [[ $((row + 1)) -eq "$line_number" ]] || break ;;
        *) [[ "$row" -eq "$line_number" ]] || break ;;
      esac
      valid_actions_ref "$value" "$controls" "$style" "$label" "$row" || return 1
      if [[ "${value#*@}" != "$target" ]]; then
        wanted="${value%%@*}@$target"
        case "$style" in
          single)
            raw="'$value'"
            wanted="'$wanted'"
            ;;
          double)
            raw="\"$value\""
            wanted="\"$wanted\""
            ;;
          *) raw=$value ;;
        esac
        case "$style" in
          folded | literal)
            offset=${line%%[![:blank:]]*}
            offset=${#offset}
            ;;
          *) offset=$(yaml_byte_offset "$line" "$column") || return ;;
        esac
        if [[ "$offset" -lt "$cursor" || "${line:offset:${#raw}}" != "$raw" ]]; then
          printf 'cannot rewrite Actions reference in %s:%s; use a literal ref\n' \
            "$label" "$row" >&2
          return 1
        fi
        rendered+="${line:cursor:offset-cursor}$wanted"
        cursor=$((offset + ${#raw}))
      fi
      IFS=$'\t' read -r row column style controls value <&3 || row=
    done
    printf '%s%s%s' "$rendered" "${line:cursor}" "$newline" || return 1
  done
  if [[ -n "$row" ]]; then
    printf 'cannot locate Actions reference in %s:%s\n' "$label" "$row" >&2
    return 1
  fi
} 3<<<"$4" <"$1"
