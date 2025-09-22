#!/usr/bin/env bash
#
# Anonymize all hostnames/shortnames in Ansible vars YAML.
# - Replaces FQDNs (something.domain.tld) with hostN.example.com
# - Replaces bare host shortnames (like "sat01") with hostN
# - Works on both single vars and lists
# - Example command: ./anon.sh all.yml vars_anon.yml

input_file="$1"
output_file="$2"

if [[ -z "$input_file" || -z "$output_file" ]]; then
  echo "Usage: $0 input.yml output.yml"
  exit 1
fi

cp "$input_file" "$output_file"

counter=1

# Replace fully qualified hostnames (e.g., foo.bar.com)
grep -oE '[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}' "$input_file" | sort -u | while read -r match; do
  sed -i "s|$match|host${counter}.example.com|g" "$output_file"
  ((counter++))
done

# Replace bare host shortnames (heuristic: alphanumeric words, not YAML keys, length >2)
grep -oE ':[[:space:]]+[a-zA-Z0-9._-]+' "$input_file" | awk '{print $2}' | sort -u | while read -r match; do
  # Skip anything that already looks like hostN or contains a dot
  if [[ ! "$match" =~ \. ]] && [[ ! "$match" =~ ^host[0-9]+$ ]]; then
    sed -i "s|\b$match\b|host${counter}|g" "$output_file"
    ((counter++))
  fi
done

echo "Anonymized vars written to $output_file"
