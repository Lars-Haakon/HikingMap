#!/bin/bash
# Download a grid of adjacent norgeskart printouts at 1:10000, extract the map
# image from each, and write them into one PDF -- one A4 page per map.

set -e
shopt -s nullglob

lat=67.330773
   # baseline in degrees (WGS84 / ETRS89)
lon=14.595255
scale=10000   # print scale, filled into request.json and used for the steps
dpi=300       # the service accepts 72, 128 or 300 (its dpiSuggestions). this
              # picks the WMTS level the map is rendered from: at 1:10000 the
              # three land on level 13, 14 and 15 -- 2.64, 1.32, 0.66 m/px

# the map is centred in EPSG:25833 -- ETRS89 / UTM zone 33N: GRS80 ellipsoid,
# central meridian 15E, scale factor 0.9996, false easting 500000. Snyder's
# series for the forward transverse Mercator, sub-millimetre at this longitude.
read -r east north < <(awk -v lat="$lat" -v lon="$lon" 'BEGIN {
    a = 6378137.0; f = 1/298.257222101
    e2 = 2*f - f*f; ep2 = e2/(1 - e2)
    k0 = 0.9996; fe = 500000; lon0 = 15
    d = atan2(0, -1)/180                       # degrees to radians
    p = lat*d; l = (lon - lon0)*d
    N = a/sqrt(1 - e2*sin(p)^2)
    t = sin(p)/cos(p); T = t*t
    C = ep2*cos(p)^2
    A = l*cos(p)
    M = a*((1 - e2/4 - 3*e2^2/64 - 5*e2^3/256)*p \
        - (3*e2/8 + 3*e2^2/32 + 45*e2^3/1024)*sin(2*p) \
        + (15*e2^2/256 + 45*e2^3/1024)*sin(4*p) \
        - (35*e2^3/3072)*sin(6*p))
    printf "%.2f %.2f\n", \
        fe + k0*N*(A + (1 - T + C)*A^3/6 + (5 - 18*T + T^2 + 72*C - 58*ep2)*A^5/120), \
        k0*(M + N*t*(A^2/2 + (5 - T + 9*C + 4*C^2)*A^4/24 \
            + (61 - 58*T + T^2 + 600*C - 330*ep2)*A^6/720))
}')
echo "baseline: $lat, $lon degrees -> EPSG:25833 $east, $north"

# the 1_A4_portrait layout prints the map into a 554.74 x 760 pt frame, and
# pdfimages gives us exactly that frame -- so a tile covers the frame's ground
step_x=$(awk -v s="$scale" 'BEGIN { printf "%.2f", 554.74 / 72 * 0.0254 * s }')
step_y=$(awk -v s="$scale" 'BEGIN { printf "%.2f", 760 / 72 * 0.0254 * s }')

cols=4        # tiles east of the baseline, baseline included
rows=2        # tiles south of the baseline, baseline included

# fill the template, ask norgeskart for a print, save it as <east>-<north>.pdf.
# the template's LON/LAT are the map centre in EPSG:25833, so metres, not degrees
fetch_map() {
    local east=$1 north=$2
    local response status path

    response=$(sed -e "s/{{LON}}/$east/g" -e "s/{{LAT}}/$north/g" \
            -e "s/{{DPI}}/$dpi/g" -e "s/{{SCALE}}/$scale/g" request.json |
        curl -s -X POST https://api.norgeskart.no/print/kv/report.pdf \
            -H "Content-Type: application/json" --data @-)

    # statusURL and downloadURL are paths on the same host
    status=$(echo "$response" | sed -n 's/.*"statusURL" *: *"\([^"]*\)".*/\1/p')
    path=$(echo "$response" | sed -n 's/.*"downloadURL" *: *"\([^"]*\)".*/\1/p')

    # rendering is asynchronous: until it is done, downloadURL serves a text
    # error with a 200 status, which curl would happily save as the .pdf
    for _ in $(seq 60); do
        if curl -s "https://api.norgeskart.no$status" | grep -q '"done":true'; then break; fi
        sleep 1
    done

    curl -sf -o "$east-$north.pdf" "https://api.norgeskart.no$path"
    echo "downloaded: $east-$north.pdf"
}

# grid of adjacent maps with the baseline at the top-left corner, indexed
# row * cols + col so row 0 is the northernmost -- columns run east, rows south
tiles=()
for (( row = 0; row < rows; row++ )); do
    for (( col = 0; col < cols; col++ )); do
        x=$(awk -v v="$east" -v d="$step_x" -v n="$col" 'BEGIN { printf "%.2f", v + d * n }')
        y=$(awk -v v="$north" -v d="$step_y" -v n="$row" 'BEGIN { printf "%.2f", v - d * n }')
        fetch_map "$x" "$y"
        tiles[row * cols + col]="$x-$y"
    done
done

image_dir="tmp"
mkdir -p "$image_dir"

# the map is the largest of the images the PDF carries (the others are the
# Kartverket logo and the scale bar)
for tile in "${tiles[@]}"; do
    pdfimages -png "$tile.pdf" "$image_dir"/img

    largest=$(ls -S "$image_dir"/*.png | head -n 1)
    mv "$largest" "$tile.png"
    echo "$tile.png  $(identify -format '%wx%h' "$tile.png")"

    rm -f "$image_dir"/*.png
done

# page order: northernmost row first, west to east -- which is now index order
pages=()
for (( row = 0; row < rows; row++ )); do
    for (( col = 0; col < cols; col++ )); do
        pages+=("${tiles[row * cols + col]}.png")
    done
done

# the extracted image is the frame, so printing it at the frame's own paper
# size (554.74 pt wide) puts the page at exactly 1:$scale. the page is then
# the map and nothing else -- 195.7 x 268.1 mm, a little under A4, because
# every norgeskart layout keeps a margin around the map
tile_w=$(identify -format '%w' "${pages[0]}")
density=$(awk -v w="$tile_w" 'BEGIN { printf "%.3f", w / (554.74 / 72) }')

convert "${pages[@]}" -units PixelsPerInch -density "$density" maps.pdf
echo "combined: maps.pdf  (${#pages[@]} pages at 1:$scale, ${density} dpi)"
