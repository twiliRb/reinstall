#!/bin/sh

# Encode UTF-8 text as a PowerShell single-quoted Base64 literal. The input is
# data and never appears as PowerShell source code.
reinstall_windows_ps_base64() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

reinstall_windows_ps_string_literal() {
    printf "'%s'" "$(reinstall_windows_ps_base64 "$1")"
}

# Update one text/attribute node with xmlstarlet so XML escaping is handled by
# the XML serializer, not by shell or sed interpolation.
reinstall_windows_xml_set_value() {
    local _reinstall_xml_file=$1
    local _reinstall_xml_xpath=$2
    local _reinstall_xml_value=$3
    xmlstarlet ed -L -N x='urn:schemas-microsoft-com:unattend' \
        -u "$_reinstall_xml_xpath" -v "$_reinstall_xml_value" "$_reinstall_xml_file"
}
