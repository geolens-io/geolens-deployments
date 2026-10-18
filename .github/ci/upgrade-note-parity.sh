#!/usr/bin/env bash
# Every "Upgrading to X" note in the chart README must reach both recipe
# READMEs and the AWS and Azure guides, which cover the same upgrade on other
# runtimes. A note that only concerns the chart goes in chart_only below with
# its reason.
#
#   upgrade-note-parity.sh [repository root]
set -euo pipefail

cd "${1:-$(dirname "${BASH_SOURCE[0]}")/../..}"

# version|reason
chart_only=(
)

targets=(terraform/*/README.md clouds/aws.md clouds/azure.md)

versions=$(sed -n 's/^Upgrading to \([0-9][0-9.]*[0-9]\).*/\1/p' helm/geolens/README.md | sort -u)
if [ -z "$versions" ]; then
  echo "no 'Upgrading to' notes found in helm/geolens/README.md; did their wording change?" >&2
  exit 1
fi

fail=0
checked=()
for version in $versions; do
  for entry in "${chart_only[@]+"${chart_only[@]}"}"; do
    [ "${entry%%|*}" = "$version" ] && continue 2
  done
  checked+=("$version")
  for file in "${targets[@]}"; do
    if ! grep -q "^Upgrading to ${version//./\\.}[^0-9.]" "$file"; then
      echo "::error file=$file::no 'Upgrading to $version' note; carry the chart README's note in this file's terms, or list it in chart_only in $0 with the reason"
      fail=1
    fi
  done
done
[ "$fail" = 0 ] && echo "upgrade notes ${checked[*]-} reach ${targets[*]}"
exit "$fail"
