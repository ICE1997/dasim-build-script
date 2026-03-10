param(
    [string]$ConfigPath = './build-config.json',
    [Parameter(Mandatory = $true)][string]$ProjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Build.Common.ps1"

$config = Load-Config -ConfigPath $ConfigPath
$project = @($config.projects | Where-Object { $_.id -eq $ProjectId })[0]
if (-not $project) { throw "未找到项目: $ProjectId" }

Start-Log -Config $config -Name "build-$ProjectId"

$ctx = New-PipelineContext -Config $config

Invoke-ProjectBuildPipeline -Config $config -Project $project -Context $ctx
Write-Log -Message "单项目构建完成: $ProjectId"
