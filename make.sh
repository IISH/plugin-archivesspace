#!/bin/sh

set -e

TARGET="target"

if [ -d "$TARGET" ]
then
    rm -fr "$TARGET"
fi
mkdir -p "${TARGET}"
rsync -av "iisg" "$TARGET"

echo "Ensure the plugin is registered in the Archivesspace config.rb file:"
echo "AppConfig[:plugins] = ['iisg']"