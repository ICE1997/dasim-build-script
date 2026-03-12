param([string]$ConfigPath = './build-config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

& "$PSScriptRoot/build-project.ps1" -ConfigPath $ConfigPath -ProjectId 'backend'
