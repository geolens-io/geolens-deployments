#!/usr/bin/env bash
# Pushes a vector and a raster dataset through a running install and fetches a
# raster tile, all through the frontend edge (#53). The kind install test runs
# it; it also works against any install reachable at $1.
#
#   ingest-smoke.sh http://127.0.0.1:8080 <admin-user> <admin-password>
#
# Exercises what a render cannot: the api and worker handing an upload over
# through /app/staging, the worker writing under a read-only root, and titiler
# reading the result through the api's tile proxy.
set -euo pipefail

base=$1
user=$2
password=$3
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

token=$(curl -sSf -X POST "$base/api/auth/login" \
  --data-urlencode "username=$user" --data-urlencode "password=$password" | jq -r .access_token)
auth="Authorization: Bearer $token"

# Prints the dataset id once the worker has ingested the file.
ingest() {
  local file=$1 job status dataset
  job=$(curl -sSf -X POST "$base/api/ingest/upload" -H "$auth" -F "file=@$file" | jq -r .job_id)
  curl -sSf -X POST "$base/api/ingest/preview/$job" -H "$auth" > /dev/null
  curl -sSf -X POST "$base/api/ingest/commit/$job" -H "$auth" \
    -H 'Content-Type: application/json' -d "{\"title\": \"smoke $(basename "$file")\"}" > /dev/null
  for _ in $(seq 1 60); do
    read -r status dataset < <(curl -sSf "$base/api/jobs/$job" -H "$auth" | jq -r '"\(.status) \(.dataset_id // "")"')
    case "$status" in
      complete) echo "$dataset"; return 0 ;;
      failed)
        echo "ingest of $file failed:" >&2
        curl -sS "$base/api/jobs/$job" -H "$auth" >&2
        return 1
        ;;
    esac
    sleep 3
  done
  echo "ingest of $file did not finish in 3 minutes (last status: $status)" >&2
  return 1
}

vector=$(mktemp -d)/smoke.geojson
cat > "$vector" <<'EOF'
{"type": "FeatureCollection", "features": [
  {"type": "Feature", "properties": {"name": "a"}, "geometry": {"type": "Point", "coordinates": [-74.0, 40.72]}},
  {"type": "Feature", "properties": {"name": "b"}, "geometry": {"type": "Point", "coordinates": [-73.98, 40.74]}}
]}
EOF

vector_id=$(ingest "$vector")
echo "vector dataset $vector_id ingested"

raster_id=$(ingest "$here/smoke.tif")
echo "raster dataset $raster_id ingested"

# smoke.tif covers lower Manhattan; tile 12/1205/1539 lies inside it.
tile=$(mktemp)
code=$(curl -sS -o "$tile" -w '%{http_code}' -H "$auth" \
  "$base/raster-tiles/$raster_id/tiles/12/1205/1539.png")
if [ "$code" != 200 ] || [ "$(head -c 4 "$tile" | tail -c 3)" != PNG ]; then
  echo "raster tile returned HTTP $code, not a PNG" >&2
  exit 1
fi
echo "raster tile served through the edge ($(wc -c < "$tile") bytes)"
