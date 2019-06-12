# plugin-archivesspace

EAD export plugin for Archivesspace

## Description

The plugin will make minor changes to the export of the EAD to match the EAD format of the XMetal EAD 2002 schema.

Because of this, all clients ( VuFind, Mint, etc.) will not break.

## Installation

Place `iisg` in the Archivematica `plugins` folder.

Ensure the plugin is registered in the config.rb file:
    
    AppConfig[:plugins] = ['iisg']

And restart Archivesspace.