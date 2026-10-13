#!/bin/sh
# Builds Web/index.html (bundled into the iPhone and Mac apps, and served as
# the playable phone on the website) from the phone shell in ../phone/index.html.
set -e
cd "$(dirname "$0")"
SRC="${1:-../phone/index.html}"
mkdir -p Web
{
  printf '%s\n' '<!doctype html><html lang="en"><head><meta charset="utf-8">'
  printf '%s\n' '<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">'
  printf '%s\n' '<style>html,body{height:100%;margin:0}body{padding:0!important;overflow:hidden}*{-webkit-tap-highlight-color:transparent;-webkit-touch-callout:none}</style>'
  printf '%s\n' '</head><body>'
  cat "$SRC"
  printf '%s\n' '</body></html>'
} > Web/index.html
echo "Wrote apple/Web/index.html"
