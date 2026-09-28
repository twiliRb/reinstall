#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo_root/lib/windows-serialize.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
marker="$tmpdir/command-ran"
value="O'Neil \"quoted\" \$HOME \`touch $marker\` & <雪>"

literal=$(reinstall_windows_ps_string_literal "$value")
[[ "$literal" =~ ^\'[A-Za-z0-9+/=]+\'$ ]]
encoded=${literal#\'}
encoded=${encoded%\'}
decoded=$(printf '%s' "$encoded" | base64 -d)
[[ "$decoded" == "$value" ]]
[[ ! -e "$marker" ]]
printf 'CHECKPOINT windows-serialize/powershell-literal: base64-roundtrip=passed utf8-bytes=%s command-sentinel=absent\n' \
    "$(printf '%s' "$decoded" | wc -c | tr -d ' ')"

xml_file="$tmpdir/unattend.xml"
cat >"$xml_file" <<'XML'
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings><component><Name>before</Name></component></settings>
</unattend>
XML
reinstall_windows_xml_set_value "$xml_file" '//x:Name' "$value"
xml_value=$(xmlstarlet sel -N x='urn:schemas-microsoft-com:unattend' -t -v '//x:Name' "$xml_file")
expected_xml_value=$(printf '%s' "$value" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g')
[[ "$xml_value" == "$expected_xml_value" ]]
[[ ! -e "$marker" ]]
printf 'CHECKPOINT windows-serialize/xml: xpath-roundtrip=passed escaped-entities=ampersand/less-than/greater-than unicode=preserved command-sentinel=absent\n'

printf 'PASS Windows value/XML serializer tests\n'
