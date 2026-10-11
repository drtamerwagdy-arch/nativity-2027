#!/usr/bin/env bash
# zoom.sh - zoom a 1080p stage video a little, adapting to how tight the camera already is.
#
#   zoom.sh inspect  IN OUTDIR                                  contact sheets, scene cuts, full frames
#   zoom.sh plan     IN OUTDIR ZMAX YSHIFT START END             zoom plan (plan.py) + review sheet with the
#                                                               crop window drawn every 30 s
#   zoom.sh preview  IN OUTDIR ZMAX YSHIFT AT START END [LOGO]   15 s clips from second AT: original and planned zoom
#   zoom.sh render   IN OUT    ZMAX YSHIFT START END [LOGO] [CUT CARD]
#                                                               the full video with the planned zoom; with CUT and
#                                                               CARD the film ends at second CUT (1 s fade to black)
#                                                               and continues with the closing card from second CARD
#
#   ZMAX    the most the picture may be zoomed (1.3 = faces up to 1.3x taller)
#   YSHIFT  where the window sits vertically, fraction of its height: 0 centre, 0.08 a little lower
#   START   zoom only from this second (after the opening cards), END until this second (0 = to the end)
#   LOGO    none | file.png:X:Y:W:OPACITY  the watermark the crop removes is re-drawn at X,Y with width W
#           (the original one is first painted out with delogo, so it never shows twice)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
mode="${1:-}"; in="${2:-}"
[[ -f "$in" ]] || { sed -n '2,16p' "$0"; exit 1; }
IFS=, read -r W H FR < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=p=0 "$in")
FPS=$(awk -v f="$FR" 'BEGIN{split(f,a,"/"); printf "%.4f", a[1]/(a[2]?a[2]:1)}')
dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$in"); dur=${dur%.*}
echo "input ${W}x${H}, ${FPS} fps, ${dur}s"

# plan OUTDIR ZMAX YSHIFT START END OFFSET [CUT]
make_plan() {
  local out=$1 zmax=$2 ys=$3 s=$4 e=$5 off=$6 cut=${7:-0}
  [[ "$e" == "0" ]] && e=$dur
  mkdir -p "$out"
  python3 "$here/plan.py" "$in" "$out" "$zmax" "$ys" "$s" "$e" "$FPS" "$off" "$cut"
}

# the zoom chain, written to a filter script file. args: PLANDIR YSHIFT S E LOGO SCRIPTFILE
# (the zoom factor is a per-frame expression of t from plan.py; the picture is scaled up by it,
#  then the centre 1920x1080 is kept, shifted down by YSHIFT of the window height)
zoom_graph() {
  local pdir=$1 ys=$2 s=$3 e=$4 logo=$5 script=$6
  local k b; k="$(cat "$pdir/zoom.expr")"; b="$(cat "$pdir/bottom.expr")"
  # window: centred horizontally; vertically at YSHIFT below centre, but never lower than the
  # audience line B(t) (in source pixels, so scaled by ih/1080 to the enlarged picture)
  local zoom="scale=w='ceil(iw*${k}/2)*2':h='ceil(ih*${k}/2)*2':eval=frame:flags=lanczos,crop=1920:1080:x='(iw-1920)/2':y='max(0,min(clip((ih-1080)/2+${ys}*1080,0,ih-1080),${b}*ih/1080-1080))'"
  if [[ "$logo" != "none" ]]; then
    IFS=: read -r lf lx ly lw la <<< "$logo"; la="${la:-1}"
    printf '%s' "[0:v]delogo=x=${lx}:y=${ly}:w=${lw}:h=${lw}:enable='between(t,${s},${e})',${zoom}[base];[1:v]scale=${lw}:-1,format=rgba,colorchannelmixer=aa=${la}[lg];[base][lg]overlay=${lx}:${ly}:enable='between(t,${s},${e})'[v]" > "$script"
  else
    printf '%s' "[0:v]${zoom}[v]" > "$script"
  fi
}
logo_input() { local logo=$1; if [[ "$logo" != "none" ]]; then IFS=: read -r lf _ <<< "$logo"; echo "-i"; echo "$lf"; fi; }

case "$mode" in
  inspect)
    out="$3"; mkdir -p "$out"
    lbl="drawtext=text='%{pts\:hms}':x=12:y=12:fontsize=40:fontcolor=white:box=1:boxcolor=black@0.6"
    rA=$(( (dur/20 + 1 + 5) / 6 ))
    ffmpeg -v error -y -i "$in" -vf "fps=1/20,scale=320:-2,tile=6x${rA}" -frames:v 1 -q:v 4 "$out/A sheet - whole video, one frame every 20s.jpg"
    ffmpeg -v error -y -i "$in" -t 120 -vf "fps=1/3,$lbl,scale=480:-2,tile=5x8" -frames:v 1 -q:v 4 "$out/B sheet - first 120s every 3s.jpg" \
      || ffmpeg -v error -y -i "$in" -t 120 -vf "fps=1/3,scale=480:-2,tile=5x8" -frames:v 1 -q:v 4 "$out/B sheet - first 120s every 3s (no labels).jpg"
    ls=$((dur-150)); [[ $ls -lt 0 ]] && ls=0
    ffmpeg -v error -y -ss "$ls" -i "$in" -vf "fps=1/3,$lbl,scale=480:-2,tile=5x10" -frames:v 1 -q:v 4 "$out/C sheet - last 150s every 3s (labels count from ${ls}s).jpg" \
      || ffmpeg -v error -y -ss "$ls" -i "$in" -vf "fps=1/3,scale=480:-2,tile=5x10" -frames:v 1 -q:v 4 "$out/C sheet - last 150s every 3s (from ${ls}s, no labels).jpg"
    for t in 20 60 $((dur/4)) $((dur/2)) $((dur*3/4)) $((dur-90)) $((dur-30)); do
      [[ $t -lt 0 ]] && continue
      pre=$((t-2)); [[ $pre -lt 0 ]] && pre=0
      ffmpeg -nostdin -v error -y -ss "$pre" -i "$in" -ss $((t-pre)) -frames:v 1 -q:v 2 "$out/D frame at ${t}s.jpg"
    done
    { echo "scene cuts (threshold 0.3), first 240s:"; ffmpeg -v info -i "$in" -t 240 -vf "select='gt(scene,0.3)',showinfo" -an -f null - 2>&1 | grep -o "pts_time:[0-9.]*" | sed 's/pts_time://' | tr '\n' ' ' || true; echo;
      ls2=$((dur-240)); [[ $ls2 -lt 0 ]] && ls2=0
      echo "scene cuts (threshold 0.3), last 240s (seconds counted from ${ls2}s):"; ffmpeg -v info -ss $ls2 -i "$in" -vf "select='gt(scene,0.3)',showinfo" -an -f null - 2>&1 | grep -o "pts_time:[0-9.]*" | sed 's/pts_time://' | tr '\n' ' ' || true; echo;
      echo; ffprobe -v error -show_entries stream=codec_name,width,height,r_frame_rate,bit_rate,pix_fmt:format=duration,size,bit_rate -of default=nw=1 "$in"; } > "$out/F info and scene cuts.txt"
    ;;

  plan)
    out="$3"; zmax="$4"; ys="$5"; s="$6"; e="$7"
    make_plan "$out" "$zmax" "$ys" "$s" "$e" 0
    # review sheet: the crop window drawn on the original every 30 s
    mkdir -p "$out/boxes"; i=0
    while read -r t cw ch x y; do
      # seek 2 s early and decode up to the exact second: the first frame after a plain input
      # seek is the preceding keyframe, which can be a different shot; -nostdin keeps ffmpeg
      # from eating the rest of this list
      pre=$(awk -v a="$t" 'BEGIN{p=a-2; if(p<0)p=0; print p}'); post=$(awk -v a="$t" -v p="$pre" 'BEGIN{print a-p}')
      ffmpeg -nostdin -v error -y -ss "$pre" -i "$in" -ss "$post" -frames:v 1 -q:v 4 \
        -vf "drawbox=x=${x}:y=${y}:w=${cw}:h=${ch}:color=yellow@0.9:t=8,drawtext=text='${t}s  zoom $(awk -v w="$cw" 'BEGIN{printf "%.2f", 1920/w}')x':x=20:y=990:fontsize=56:fontcolor=yellow:box=1:boxcolor=black@0.6,scale=480:-2" \
        "$out/boxes/$(printf '%04d' "$i").jpg" </dev/null || true
      i=$((i+1))
    done < "$out/boxes.txt"
    rows=$(( (i + 4) / 5 )); [[ $rows -lt 1 ]] && rows=1
    ffmpeg -v error -y -pattern_type glob -i "$out/boxes/*.jpg" -vf "tile=5x${rows}" -q:v 4 "$out/G review sheet - crop window every 30s.jpg" && rm -rf "$out/boxes"
    ;;

  preview)
    out="$3"; zmax="$4"; ys="$5"; at="$6"; s="$7"; e="$8"; logo="${9:-none}"; mkdir -p "$out"
    [[ "$e" == "0" ]] && e=$dur
    make_plan "$out/plan-at-${at}" "$zmax" "$ys" "$s" "$e" "$at" >/dev/null
    ffmpeg -v error -y -ss "$at" -t 15 -i "$in" -c:v libx264 -preset fast -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$out/preview at ${at}s - original.mp4"
    zoom_graph "$out/plan-at-${at}" "$ys" "$(awk -v a="$s" -v o="$at" 'BEGIN{print a-o}')" "$(awk -v a="$e" -v o="$at" 'BEGIN{print a-o}')" "$logo" "$out/plan-at-${at}/graph.txt"
    mapfile -t li < <(logo_input "$logo")
    ffmpeg -v error -y -ss "$at" -t 15 -i "$in" "${li[@]}" -filter_complex_script "$out/plan-at-${at}/graph.txt" -map "[v]" -map 0:a -c:v libx264 -preset fast -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$out/preview at ${at}s - planned zoom (max ${zmax}x).mp4"
    grep -m1 "zoom inside" "$out/plan-at-${at}/summary.txt" || true
    ;;

  render)
    out="$3"; zmax="$4"; ys="$5"; s="$6"; e="$7"; logo="${8:-none}"; cut="${9:-0}"; card="${10:-0}"
    [[ "$e" == "0" ]] && e=$dur
    pdir="$(dirname "$out")/plan"; make_plan "$pdir" "$zmax" "$ys" "$s" "$e" 0 "$cut"
    zoom_graph "$pdir" "$ys" "$s" "$e" "$logo" "$pdir/graph.txt"
    mapfile -t li < <(logo_input "$logo")
    if [[ "$cut" != "0" ]]; then
      # the film ends at CUT (fade to black over the last second); then, when a logo is given, the
      # church logo fades in on black, holds and fades out (LOGOCARD seconds); then the closing card
      fo=$(awk -v c="$cut" 'BEGIN{print c-1}'); lc="${LOGOCARD:-5}"
      { printf '[0:v]split[src][card];[src]'; sed 's/^\[0:v\]//; s/\[v\]$//' "$pdir/graph.txt"
        printf ',trim=0:%s,setpts=PTS-STARTPTS,fade=t=out:st=%s:d=1[a];' "$cut" "$fo"
        printf '[card]trim=%s,setpts=PTS-STARTPTS,fade=t=in:st=0:d=1[b];' "$card"
        printf '[0:a]asplit[sa][ca];[sa]atrim=0:%s,asetpts=PTS-STARTPTS,afade=t=out:st=%s:d=1,aformat=sample_rates=48000:channel_layouts=stereo[aa];' "$cut" "$fo"
        printf '[ca]atrim=%s,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=1,aformat=sample_rates=48000:channel_layouts=stereo[ab];' "$card"
        if [[ "$logo" != "none" ]]; then
          IFS=: read -r lf _ <<< "$logo"
          printf 'color=c=black:s=1920x1080:r=%s:d=%s,format=yuv420p[blk];movie=%s,scale=300:-1,format=rgba[lgc];' "$FPS" "$lc" "$lf"
          printf '[blk][lgc]overlay=(W-w)/2:(H-h)/2,fade=t=in:st=0.5:d=1,fade=t=out:st=%s:d=1,format=yuv420p[l];' "$(awk -v d="$lc" 'BEGIN{print d-1.5}')"
          printf 'anullsrc=r=48000:cl=stereo:d=%s,aformat=sample_rates=48000:channel_layouts=stereo[al];' "$lc"
          printf '[a][aa][l][al][b][ab]concat=n=3:v=1:a=1[v][au]'
        else
          printf '[a][aa][b][ab]concat=n=2:v=1:a=1[v][au]'
        fi; } > "$pdir/graph-cut.txt"
      ffmpeg -hide_banner -loglevel warning -stats -y -i "$in" "${li[@]}" -filter_complex_script "$pdir/graph-cut.txt" -map "[v]" -map "[au]" \
        -c:v libx264 -preset medium -crf 20 -maxrate 9M -bufsize 18M -pix_fmt yuv420p -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$out"
    else
      ffmpeg -hide_banner -loglevel warning -stats -y -i "$in" "${li[@]}" -filter_complex_script "$pdir/graph.txt" -map "[v]" -map 0:a \
        -c:v libx264 -preset medium -crf 20 -maxrate 9M -bufsize 18M -pix_fmt yuv420p -c:a copy -movflags +faststart "$out"
    fi
    ls -l "$out"
    ;;
  *) echo "unknown mode"; exit 1;;
esac
