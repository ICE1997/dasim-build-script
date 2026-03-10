param([string]$ConfigPath = './build-config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Build.Common.ps1"

$config = Load-Config -ConfigPath $ConfigPath
Start-Log -Config $config -Name 'publish-output'

$ctx = New-PipelineContext -Config $config

foreach ($p in $config.projects) {
    $dir = Join-Path $ctx.workspaceDir $p.source.dir
    if (Test-Path $dir) { $ctx.projectCommits[$p.id] = Get-ProjectCommitId -Config $config -ProjectDir $dir }
}

Invoke-ReleaseStage -Config $config -Context $ctx
Invoke-UploadStage -Config $config -Context $ctx
Write-Log -Message '发布完成'
