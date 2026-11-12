#!/bin/zsh
# Builds a universal (Apple silicon + Intel) Diary.app and zips it into dist/ for a GitHub release.
set -e
cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Diary.app/Contents/Info.plist)
mkdir -p dist
rm -f "dist/Diary-$VERSION.zip"
# ditto keeps the app bundle's structure and signature intact (plain zip can break it)
ditto -c -k --keepParent Diary.app "dist/Diary-$VERSION.zip"
echo "Packaged dist/Diary-$VERSION.zip ($(du -h "dist/Diary-$VERSION.zip" | cut -f1)) — $(lipo -archs Diary.app/Contents/MacOS/Diary)"
