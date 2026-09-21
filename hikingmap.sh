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

poll_retries=10   # times to ask whether a map has finished rendering, 2 s apart

# fill the template, ask norgeskart for a print, save it as <east>-<north>.pdf.
# the template's LON/LAT are the map centre in EPSG:25833, so metres, not degrees
fetch_map() {
    local east=$1 north=$2
    local response status path poll try

    response=$(sed -e "s/{{LON}}/$east/g" -e "s/{{LAT}}/$north/g" \
            -e "s/{{DPI}}/$dpi/g" -e "s/{{SCALE}}/$scale/g" request.json |
        curl -s -X POST https://api.norgeskart.no/print/kv/report.pdf \
            -H "Content-Type: application/json" --data @-)

    # statusURL and downloadURL are paths on the same host
    status=$(echo "$response" | sed -n 's/.*"statusURL" *: *"\([^"]*\)".*/\1/p')
    path=$(echo "$response" | sed -n 's/.*"downloadURL" *: *"\([^"]*\)".*/\1/p')

    # rendering is asynchronous: until it is done, downloadURL serves a text
    # error with a 200 status, which curl would happily save as the .pdf. a map
    # that is still not done after the last poll is fatal -- carrying on would
    # put that error text in the PDF and leave a hole in the grid
    for (( try = 1; try <= poll_retries; try++ )); do
        poll=$(curl -s "https://api.norgeskart.no$status")
        # a canceled job reports done:true and still hands out a downloadURL,
        # so it has to be caught before the done check
        if echo "$poll" | grep -q '"status":"canceled"'; then
            echo "$east-$north: $poll" >&2
            exit 1
        fi
        if echo "$poll" | grep -q '"done":true'; then break; fi
        if (( try == poll_retries )); then
            echo "$east-$north: not rendered after $poll_retries polls: $poll" >&2
            exit 1
        fi
        sleep 2
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

# scratch space for the extracted images and the pages built from them: a fresh
# directory per run, removed on the way out however the script ends
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# the map is the largest of the images the PDF carries (the others are the
# Kartverket logo and the scale bar)
for tile in "${tiles[@]}"; do
    # each tile extracts under its own prefix, so the glob below can only ever
    # see this PDF's images -- never a leftover from the tile before it
    pdfimages -png "$tile.pdf" "$tmp_dir/$tile"

    images=("$tmp_dir/$tile"-*.png)
    (( ${#images[@]} )) || { echo "no images in $tile.pdf" >&2; exit 1; }

    largest=$(ls -S "${images[@]}" | head -n 1)
    mv "$largest" "$tile.png"
    echo "$tile.png  $(identify -format '%wx%h' "$tile.png")"
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

# page number in the bottom-right corner. the sizes are what they measure on
# paper -- 14 pt text, 6 mm in from both edges -- converted to pixels at the
# page's own density, so they stay put whatever dpi the map was rendered at
number_px=$(awk -v d="$density" 'BEGIN { printf "%.0f", 14 / 72 * d }')
margin_px=$(awk -v d="$density" 'BEGIN { printf "%.0f", 6 / 25.4 * d }')

numbered=()
for i in "${!pages[@]}"; do
    out="$tmp_dir/page-$((i + 1)).png"
    # drawn twice: a fat white stroke first, then the number on top of it, so it
    # carries its own halo and stays readable over the map without sitting in a box
    convert "${pages[i]}" \
        -gravity SouthEast -pointsize "$number_px" \
        -stroke white -strokewidth "$(( number_px / 8 + 1 ))" -fill white \
        -annotate "+$margin_px+$margin_px" "$((i + 1))" \
        -stroke none -fill black \
        -annotate "+$margin_px+$margin_px" "$((i + 1))" "$out"
    numbered+=("$out")
done

# front page: the whole grid on one sheet, laid out as it lies on the ground --
# $cols thumbnails across, $rows down -- each carrying its page number in the
# middle. the grid is wider than it is tall, so it goes on the sheet turned a
# quarter turn. a $cols x $rows grid of portrait tiles is a hair narrower than
# A4 turned on its side, so the cells are stretched to the sheet's own aspect
# rather than left with a white margin -- 3% on a thumbnail, and no map is cropped
a4_w=$(awk -v d="$density" 'BEGIN { printf "%.0f", 595.28 / 72 * d }')
a4_h=$(awk -v d="$density" 'BEGIN { printf "%.0f", 841.89 / 72 * d }')

border=2
cell_w=$(( a4_h / cols - 2 * border ))   # $cols cells fill A4's long edge
cell_h=$(( a4_w / rows - 2 * border ))   # $rows cells fill its short edge
cell_number_px=$(( cell_w / 2 ))

cells=()
for i in "${!pages[@]}"; do
    out="$tmp_dir/cell-$((i + 1)).png"
    convert "${pages[i]}" -resize "${cell_w}x${cell_h}!" \
        -bordercolor black -border "$border" \
        -gravity Center -pointsize "$cell_number_px" \
        -fill '#e00000' -stroke white -strokewidth "$(( cell_number_px / 40 + 1 ))" \
        -annotate +0+0 "$((i + 1))" "$out"
    cells+=("$out")
done

montage "${cells[@]}" -tile "${cols}x${rows}" -geometry +0+0 \
    -background white "$tmp_dir/grid.png"

# a quarter turn clockwise -- north ends up pointing to the right edge, so the
# page is read turned anticlockwise. the resize only takes up the few pixels
# the cells lost to integer division, so the sheet is exactly A4
convert "$tmp_dir/grid.png" -rotate -90 \
    -resize "${a4_w}x${a4_h}!" "$tmp_dir/front.png"

convert "$tmp_dir/front.png" "${numbered[@]}" \
    -units PixelsPerInch -density "$density" maps.pdf
echo "combined: maps.pdf  (front page + ${#pages[@]} pages at 1:$scale, ${density} dpi)"
