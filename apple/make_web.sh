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
  printf '<script>window.LARCH_VERSION=%s;</script>\n' "'$(tr -d '[:space:]' < ../VERSION 2>/dev/null || echo dev)'"
  printf '%s\n' '</head><body>'
  cat "$SRC"
  printf '%s\n' '</body></html>'
} > Web/index.html
# The built-in Java engine ships with the apps so Java runs offline.
rm -rf Web/j2me-lite && cp -R ../site/j2me/lite Web/j2me-lite
# The VoIP (SIP) library, loaded only when VoIP is switched on.
rm -rf Web/voip && cp -R ../site/voip Web/voip
echo "Wrote apple/Web/index.html and Web/j2me-lite"
