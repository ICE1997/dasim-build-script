; Inno Setup script template
; Placeholders will be rendered by Build.Common.ps1 before calling ISCC.
; Supported placeholders:
; {{APP_NAME}} {{APP_VERSION}} {{APP_PUBLISHER}} {{DEFAULT_DIR_NAME}}
; {{OUTPUT_DIR}} {{OUTPUT_BASE_FILENAME}} {{DISK_SLICE_SIZE}} {{SOURCE_DIR}} {{EXTERNAL_FLAG}}

[Setup]
AppName={{APP_NAME}}
AppVersion={{APP_VERSION}}
AppPublisher={{APP_PUBLISHER}}
DefaultDirName={{DEFAULT_DIR_NAME}}
OutputDir={{OUTPUT_DIR}}
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma2
SolidCompression=yes
DiskSpanning=yes
DiskSliceSize={{DISK_SLICE_SIZE}}

[Files]
Source: "{{SOURCE_DIR}}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs{{EXTERNAL_FLAG}}
