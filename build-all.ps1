param([string]$ConfigPath = './build-config.json')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Build.Common.ps1"

$config = Load-Config -ConfigPath $ConfigPath
Start-Log -Config $config -Name 'build-all'
Write-Log -Message '流水线开始'

$ctx = New-PipelineContext -Config $config

foreach ($stage in @('build', 'release', 'upload')) {
    switch ($stage) {
        'build' { Write-Log -Message '[Stage] build'; Invoke-BuildStage -Config $config -Context $ctx -ConfigPath $ConfigPath }
        'release' { Write-Log -Message '[Stage] release'; Invoke-ReleaseStage -Config $config -Context $ctx }
        'upload' { Write-Log -Message '[Stage] upload'; Invoke-UploadStage -Config $config -Context $ctx }
        default { throw "未知阶段: $stage" }
    }
}

Write-Log -Message '流水线完成'
