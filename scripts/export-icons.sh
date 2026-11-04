#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
node design/icons/scripts/export.mjs --native --assets
node design/icons/scripts/check.mjs --native --out docs/screenshots/v0.2/icons
node design/app-icon/export.mjs
