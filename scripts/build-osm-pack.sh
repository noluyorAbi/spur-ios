#!/bin/bash
# Builds the bundled offline road pack for the Dallas area (SPEC 14.2).
#
# Downloads the public OpenStreetMap extract (about 47 MB) into the gitignored build/osm/, cuts it
# into z13 road tiles with the parent's extractor (run by its absolute path, output to stdout,
# nothing written into the parent repo) and streams the tiles straight into the pack builder, so
# no uncompressed tile ever lands on disk. The pack (gitignored, like the font) goes to
# Spur/Resources/OSM/roads.spurpack; the app works without it.
#
# Road data © OpenStreetMap contributors, ODbL.
set -euo pipefail
cd "$(dirname "$0")/.."

# The parent web app (not public), for its parsers and scripts: SPUR_PARENT, else the path in
# Config/Local.parent (gitignored); without either the parent steps are skipped.
PARENT="${SPUR_PARENT:-$(cat "$(cd "$(dirname "$0")/.." && pwd)/Config/Local.parent" 2>/dev/null || true)}"
[[ -n "$PARENT" && -d "$PARENT" ]] || { echo "build-osm-pack needs the parent's scripts/extract-osm-tiles.py: set SPUR_PARENT. Without a pack Spur loads road data live from Overpass." >&2; exit 1; }
URL="https://download.bbbike.org/osm/bbbike/Dallas/Dallas.osm.pbf"
WORK=build/osm
PBF="$WORK/Dallas.osm.pbf"
OUT=Spur/Resources/OSM/roads.spurpack

mkdir -p "$WORK" "$(dirname "$OUT")"
echo "free disk: $(df -h . | tail -1 | awk '{print $4}')"

if [ ! -s "$PBF" ]; then
  echo "downloading $URL"
  curl -fL --retry 3 --retry-delay 5 -A "Spur/1.1 pack builder" -o "$PBF.part" "$URL"
  mv "$PBF.part" "$PBF"
fi
echo "extract: $(ls -lh "$PBF" | awk '{print $5}') $PBF"
# The extract's own timestamp when osmium can read it, else the download time.
SOURCE_DATE=$(uv run --quiet --with osmium python3 -c "import osmium,sys; print(osmium.io.Reader(sys.argv[1], osmium.osm.osm_entity_bits.NOTHING).header().get('osmosis_replication_timestamp') or '')" "$PBF" 2>/dev/null || true)
[ -n "$SOURCE_DATE" ] || SOURCE_DATE=$(date -u -r "$PBF" +%Y-%m-%dT%H:%M:%SZ)
echo "source date: $SOURCE_DATE"
# The extract's own box (s,w,n,e) from the pbf header, written as the pack's box: tiles crossing
# it hold only part of their roads; the app serves them, lists them as missing and fetches them
# live when allowed (RoadPack.isComplete).
BBOX=$(uv run --quiet --with osmium python3 -c "import osmium,sys; b=osmium.io.Reader(sys.argv[1], osmium.osm.osm_entity_bits.NOTHING).header().box(); print(f'{b.bottom_left.lat},{b.bottom_left.lon},{b.top_right.lat},{b.top_right.lon}')" "$PBF")
echo "extract box: $BBOX"

swiftc -O -swift-version 6 -o "$WORK/osm-pack" \
  Spur/Domain/Model/LatLon.swift Spur/Domain/OSM/OSMGeo.swift Spur/Domain/OSM/OSMModel.swift \
  Spur/Domain/OSM/Tiles.swift Spur/Domain/OSM/RoadPack.swift tools/osm-pack/main.swift

uv run --quiet --with osmium python3 "$PARENT/scripts/extract-osm-tiles.py" "$PBF" \
  | "$WORK/osm-pack" --out "$OUT" --area "Dallas" --source "$URL" --source-date "$SOURCE_DATE" --bbox "$BBOX"

ls -lh "$OUT"
