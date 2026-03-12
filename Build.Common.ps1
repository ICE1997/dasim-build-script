Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -Path $Path)) { New-Item -Path $Path -ItemType Directory | Out-Null }
}

function Convert-ToAbsolutePath {
    param([string]$Path, [Parameter(Mandatory = $true)][string]$BaseDir)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $BaseDir $Path)
}

function New-PipelineContext {
    param([Parameter(Mandatory = $true)]$Config)

    return [PSCustomObject]@{
        logDir = $Config.parameters.paths.logDir
        workspaceDir = $Config.parameters.paths.workspaceDir
        outputDir = $Config.parameters.paths.outputDir
        packageDir = $Config.parameters.paths.packageDir
        projectCommits = @{}
        version = ''
        packageFiles = @()
        shaFile = ''
    }
}

function Test-ToolNameSupported {
    param([string]$Tool)
    return @('maven', 'npm', 'cmake') -contains $Tool
}

function Assert-Config {
    param([Parameter(Mandatory = $true)]$Config)

    if (-not $Config.parameters -or -not $Config.parameters.paths) { throw '配置缺少 parameters.paths' }
    foreach ($k in @('workspaceDir', 'outputDir', 'packageDir', 'logDir')) {
        if ([string]::IsNullOrWhiteSpace((Get-OptionalProperty -Object $Config.parameters.paths -Name $k))) {
            throw "配置缺少路径参数: parameters.paths.$k"
        }
    }

    $projectIds = @{}
    foreach ($project in @($Config.projects)) {
        if (-not $project -or [string]::IsNullOrWhiteSpace($project.id)) { throw 'projects[].id 不能为空' }
        if ($projectIds.ContainsKey($project.id)) { throw "projects.id 重复: $($project.id)" }
        $projectIds[$project.id] = $true

        if (-not $project.source -or [string]::IsNullOrWhiteSpace($project.source.dir)) {
            throw "project($($project.id)) 缺少 source.dir"
        }
        $tool = if ($project.build) { $project.build.tool } else { $null }
        if ([string]::IsNullOrWhiteSpace($tool)) { throw "project($($project.id)) 缺少 build.tool" }
        if (-not (Test-ToolNameSupported -Tool $tool)) {
            throw "project($($project.id)) 不支持的 build.tool: $tool"
        }
    }
}

function Normalize-Config {
    param([Parameter(Mandatory = $true)]$Raw)

    # 简化结构 -> 内部结构
    $normalized = [PSCustomObject]@{
        tools = $Raw.tools
        parameters = [PSCustomObject]@{
            paths = [PSCustomObject]@{
                workspaceDir = $Raw.paths.workspace
                outputDir = $Raw.paths.output
                packageDir = $Raw.paths.package
                dependencyDir = $Raw.paths.dependencies
                logDir = $Raw.paths.logs
            }
            auth = [PSCustomObject]@{ git = $null }
            version = [PSCustomObject]@{ current = $Raw.version }
        }
        stages = [PSCustomObject]@{
            build = [PSCustomObject]@{
                enabled = if ($Raw.build -and $Raw.build.enabled -ne $null) { [bool]$Raw.build.enabled } else { $true }
                projects = if ($Raw.build -and $Raw.build.projects) { @($Raw.build.projects) } else { @() }
                parallel = [PSCustomObject]@{
                    enabled = if ($Raw.build -and $Raw.build.parallel -and $Raw.build.parallel.enabled -ne $null) { [bool]$Raw.build.parallel.enabled } else { $true }
                    maxWorkers = if ($Raw.build -and $Raw.build.parallel -and $Raw.build.parallel.maxWorkers) { [int]$Raw.build.parallel.maxWorkers } else { 2 }
                }
                hooks = if ($Raw.build -and $Raw.build.hooks) { $Raw.build.hooks } else { $null }
            }
            release = [PSCustomObject]@{
                enabled = if ($Raw.release -and $Raw.release.enabled -ne $null) { [bool]$Raw.release.enabled } else { $true }
                version = [PSCustomObject]@{ bump = if ($Raw.release -and $Raw.release.bump) { $Raw.release.bump } else { 'patch' } }
                package = [PSCustomObject]@{
                    name = if ($Raw.release -and $Raw.release.packageName) { $Raw.release.packageName } else { $null }
                    productName = if ($Raw.release -and $Raw.release.productName) { $Raw.release.productName } else { $null }
                    exclude = if ($Raw.release -and $Raw.release.exclude) { @($Raw.release.exclude) } else { @() }
                    volumeSize = if ($Raw.release) { $Raw.release.volumeSize } else { $null }
                    inno = if ($Raw.release -and $Raw.release.inno) { $Raw.release.inno } else { $null }
                }
                hooks = if ($Raw.release -and $Raw.release.hooks) { $Raw.release.hooks } else { $null }
            }
            upload = [PSCustomObject]@{
                enabled = if ($Raw.upload -and $Raw.upload.enabled -ne $null) { [bool]$Raw.upload.enabled } else { $true }
                uploadSha256 = if ($Raw.upload -and $Raw.upload.uploadSha256 -ne $null) { [bool]$Raw.upload.uploadSha256 } else { $true }
                ftp = $Raw.upload.ftp
                hooks = if ($Raw.upload -and $Raw.upload.hooks) { $Raw.upload.hooks } else { $null }
            }
        }
        projects = $Raw.projects
    }

    return $normalized
}

function Load-Config {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -Path $ConfigPath)) { throw "配置文件不存在: $ConfigPath" }

    $fullConfigPath = (Resolve-Path -Path $ConfigPath).Path
    $configDir = Split-Path -Parent $fullConfigPath

    $raw = Get-Content -Path $fullConfigPath -Raw | ConvertFrom-Json -Depth 50
    $config = Normalize-Config -Raw $raw

    # 统一将相对路径按配置文件目录解析，避免受执行目录影响
    $paths = $config.parameters.paths
    $paths.workspaceDir = Convert-ToAbsolutePath -Path $paths.workspaceDir -BaseDir $configDir
    $paths.outputDir = Convert-ToAbsolutePath -Path $paths.outputDir -BaseDir $configDir
    $paths.packageDir = Convert-ToAbsolutePath -Path $paths.packageDir -BaseDir $configDir
    $paths.logDir = Convert-ToAbsolutePath -Path $paths.logDir -BaseDir $configDir
    $paths.dependencyDir = Convert-ToAbsolutePath -Path $paths.dependencyDir -BaseDir $configDir

    Assert-Config -Config $config
    return $config
}

function Start-Log {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Name)
    Ensure-Directory -Path $Config.parameters.paths.logDir
    $script:LogFile = Join-Path $Config.parameters.paths.logDir ("{0}-{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    "==== START $Name $(Get-Date -Format o) ====" | Set-Content -Path $script:LogFile -Encoding UTF8
    Write-Host "[Log] $script:LogFile"
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 }
}


function Get-OptionalProperty {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Get-ToolConfig {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ToolKey)
    return Get-OptionalProperty -Object $Config.tools -Name $ToolKey
}

function Resolve-Tool {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ToolKey, [string]$Default)

    $toolCfg = Get-ToolConfig -Config $Config -ToolKey $ToolKey
    if (-not $toolCfg) { return $Default }

    $toolPath = Get-OptionalProperty -Object $toolCfg -Name 'path'
    if (-not [string]::IsNullOrWhiteSpace($toolPath)) { return $toolPath }
    return $Default
}

function Invoke-Command {
    param([Parameter(Mandatory = $true)][string]$Command, [Parameter(Mandatory = $true)][string[]]$Args, [string]$WorkingDirectory)
    $argText = ($Args -join ' ')
    Write-Log -Message "执行: $Command $argText"

    Push-Location ($WorkingDirectory ? $WorkingDirectory : (Get-Location).Path)
    try {
        $output = & $Command @Args 2>&1
        foreach ($line in $output) { Write-Log -Message "$line" }
        if ($LASTEXITCODE -ne 0) { throw "命令执行失败($LASTEXITCODE): $Command $argText" }
    }
    finally { Pop-Location }
}

function New-GitUrl {
    param([string]$Url, [string]$Username, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($Password)) { return $Url }
    $uri = [System.Uri]$Url
    return "{0}://{1}:{2}@{3}{4}" -f $uri.Scheme, ([System.Uri]::EscapeDataString($Username)), ([System.Uri]::EscapeDataString($Password)), $uri.Authority, $uri.PathAndQuery
}

function Get-GitCredential {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Project)
    $globalGit = Get-ToolConfig -Config $Config -ToolKey 'git'
    $sourceGit = Get-OptionalProperty -Object $Project.source -Name 'git'
    $projectUser = Get-OptionalProperty -Object $sourceGit -Name 'username'
    $projectPass = Get-OptionalProperty -Object $sourceGit -Name 'password'

    [PSCustomObject]@{
        username = if ($projectUser) { $projectUser } else { (Get-OptionalProperty -Object $globalGit -Name 'username') }
        password = if ($projectPass) { $projectPass } else { (Get-OptionalProperty -Object $globalGit -Name 'password') }
    }
}

function Invoke-Hook {
    param([Parameter(Mandatory = $true)]$Hook, [Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$WorkDir)
    if (-not $Hook -or [string]::IsNullOrWhiteSpace($Hook.command)) { return }

    Ensure-Directory -Path $Context.logDir
    $ctxFile = Join-Path $Context.logDir ("ctx-{0}-{1}.json" -f $Context.stage, [Guid]::NewGuid().ToString('N'))
    $Context | ConvertTo-Json -Depth 30 | Set-Content -Path $ctxFile -Encoding UTF8
    $args = @()
    if ($Hook.args) { $args += @($Hook.args) }
    $args += @('-ContextFile', $ctxFile)

    Invoke-Command -Command $Hook.command -Args $args -WorkingDirectory $WorkDir
}

function Sync-ProjectRepo {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Project)

    $git = Resolve-Tool -Config $Config -ToolKey 'git' -Default 'git'
    Ensure-Directory -Path $Config.parameters.paths.workspaceDir

    $projectDir = Join-Path $Config.parameters.paths.workspaceDir $Project.source.dir
    $cred = Get-GitCredential -Config $Config -Project $Project
    $url = New-GitUrl -Url $Project.source.git.url -Username $cred.username -Password $cred.password
    $branch = $Project.source.git.branch

    if (-not (Test-Path -Path $projectDir)) {
        Invoke-Command -Command $git -Args @('clone', '--branch', $branch, '--single-branch', $url, $projectDir)
    }
    else {
        Invoke-Command -Command $git -Args @('remote', 'set-url', 'origin', $url) -WorkingDirectory $projectDir
        Invoke-Command -Command $git -Args @('fetch', 'origin', $branch) -WorkingDirectory $projectDir
        Invoke-Command -Command $git -Args @('checkout', $branch) -WorkingDirectory $projectDir
        Invoke-Command -Command $git -Args @('reset', '--hard', ("origin/{0}" -f $branch)) -WorkingDirectory $projectDir
    }

    return $projectDir
}

function Get-ProjectCommitId {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ProjectDir)
    $git = Resolve-Tool -Config $Config -ToolKey 'git' -Default 'git'
    Push-Location $ProjectDir
    try { return (& $git rev-parse HEAD) } finally { Pop-Location }
}


function Resolve-DependencyPath {
    param([Parameter(Mandatory = $true)][string]$DependencyRoot, [Parameter(Mandatory = $true)][string]$PathText)
    if ([System.IO.Path]::IsPathRooted($PathText)) { return $PathText }
    return (Join-Path $DependencyRoot $PathText)
}

function New-DirectoryLink {
    param([Parameter(Mandatory = $true)][string]$LinkPath, [Parameter(Mandatory = $true)][string]$TargetPath)

    if (-not (Test-Path -Path $TargetPath)) {
        throw "node_modules link 源目录不存在: $TargetPath"
    }

    if (Test-Path -Path $LinkPath) {
        Remove-Item -Path $LinkPath -Recurse -Force
    }

    Ensure-Directory -Path (Split-Path -Path $LinkPath -Parent)

    try {
        New-Item -Path $LinkPath -ItemType Junction -Value $TargetPath | Out-Null
    }
    catch {
        $mk = 'mklink /J "{0}" "{1}"' -f $LinkPath, $TargetPath
        cmd /c $mk | Out-Null
    }
}

function Link-NpmNodeModules {
    param([Parameter(Mandatory = $true)]$Project, [Parameter(Mandatory = $true)][string]$ProjectDir, [Parameter(Mandatory = $true)][string]$DependencyRoot)

    $links = @($Project.build.nodeModulesLinks)
    if ($links.Count -eq 0) { return }

    foreach ($item in $links) {
        if ([string]::IsNullOrWhiteSpace($item.from)) { throw "nodeModulesLinks.from 不能为空 (project=$($Project.id))" }

        $targetRoot = if ($item.to) { Join-Path $ProjectDir $item.to } else { $ProjectDir }
        Ensure-Directory -Path $targetRoot

        $linkPath = Join-Path $targetRoot 'node_modules'
        $sourcePath = Resolve-DependencyPath -DependencyRoot $DependencyRoot -PathText $item.from
        Write-Log -Message "链接 node_modules: $linkPath -> $sourcePath"
        New-DirectoryLink -LinkPath $linkPath -TargetPath $sourcePath
    }
}


function Resolve-ToolDependencyDir {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$ToolKey, [string]$DefaultSubDir)

    $toolCfg = Get-ToolConfig -Config $Config -ToolKey $ToolKey
    $toolDep = if ($toolCfg -and -not ($toolCfg -is [string])) { Get-OptionalProperty -Object $toolCfg -Name 'dependencyDir' } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($toolDep)) { return $toolDep }

    $depRoot = $Config.parameters.paths.dependencyDir
    if ([string]::IsNullOrWhiteSpace($depRoot)) { return $null }
    if ([string]::IsNullOrWhiteSpace($DefaultSubDir)) { return $depRoot }
    return (Join-Path $depRoot $DefaultSubDir)
}

function Invoke-ProjectBuildTool {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Project, [Parameter(Mandatory = $true)][string]$ProjectDir)

    switch ($Project.build.tool) {
        'maven' {
            $mvn = Resolve-Tool -Config $Config -ToolKey 'maven' -Default 'mvn'
            $m2 = Resolve-ToolDependencyDir -Config $Config -ToolKey 'maven' -DefaultSubDir 'm2-repository'
            Ensure-Directory -Path $m2

            $args = @('clean', 'package', '-o', ("-Dmaven.repo.local={0}" -f $m2))
            $mavenTool = Get-ToolConfig -Config $Config -ToolKey 'maven'
            $settingsXml = if ($mavenTool) { [string](Get-OptionalProperty -Object $mavenTool -Name 'settingsXml') } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($settingsXml)) {
                $settingsPath = if ([System.IO.Path]::IsPathRooted($settingsXml)) { $settingsXml } else { Join-Path $PSScriptRoot $settingsXml }
                if (-not (Test-Path -Path $settingsPath)) { throw "tools.maven.settingsXml 不存在: $settingsPath" }
                $args += @('-s', $settingsPath)
            }
            if ($Project.build.args) { $args += @($Project.build.args) }
            Invoke-Command -Command $mvn -Args $args -WorkingDirectory $ProjectDir
        }
        'npm' {
            $npm = Resolve-Tool -Config $Config -ToolKey 'npm' -Default 'npm'
            $cache = Resolve-ToolDependencyDir -Config $Config -ToolKey 'npm' -DefaultSubDir 'npm-cache'
            Ensure-Directory -Path $cache
            $env:npm_config_cache = $cache

            $ci = @('ci', '--offline', '--cache', $cache)
            if ($Project.build.ciArgs) { $ci += @($Project.build.ciArgs) }

            $skipCi = ($Project.build.skipCi -eq $true)
            if (-not $skipCi) {
                Invoke-Command -Command $npm -Args $ci -WorkingDirectory $ProjectDir
            }

            Link-NpmNodeModules -Project $Project -ProjectDir $ProjectDir -DependencyRoot $Config.parameters.paths.dependencyDir

            $script = if ($Project.build.script) { $Project.build.script } else { 'build' }
            $build = @('run', $script)
            if ($Project.build.args) { $build += @($Project.build.args) }
            Invoke-Command -Command $npm -Args $build -WorkingDirectory $ProjectDir
        }
        'cmake' {
            $cmake = Resolve-Tool -Config $Config -ToolKey 'cmake' -Default 'cmake'
            $buildDir = if ($Project.build.buildDir) { Join-Path $ProjectDir $Project.build.buildDir } else { Join-Path $ProjectDir 'build' }
            Ensure-Directory -Path $buildDir

            $cfg = @('-S', $ProjectDir, '-B', $buildDir)
            if ($Project.build.generator) { $cfg += @('-G', $Project.build.generator) }
            if ($Project.build.configureArgs) { $cfg += @($Project.build.configureArgs) }
            Invoke-Command -Command $cmake -Args $cfg -WorkingDirectory $ProjectDir

            $build = @('--build', $buildDir)
            if ($Project.build.config) { $build += @('--config', $Project.build.config) }
            if ($Project.build.buildArgs) { $build += @($Project.build.buildArgs) }
            Invoke-Command -Command $cmake -Args $build -WorkingDirectory $ProjectDir
        }
        default { throw "不支持的构建工具: $($Project.build.tool)" }
    }
}

function Copy-WithExclude {
    param([string]$Source, [string]$Destination, [string[]]$Exclude)
    Ensure-Directory -Path $Destination
    if (-not (Test-Path -Path $Source)) { throw "产物目录不存在: $Source" }

    Get-ChildItem -Path $Source -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Source.Length).TrimStart('\\','/')
        $skip = $false
        foreach ($p in ($Exclude | Where-Object { $_ })) {
            if ($rel -like $p -or $_.Name -like $p) { $skip = $true; break }
        }
        if (-not $skip) {
            $target = Join-Path $Destination $rel
            Ensure-Directory -Path (Split-Path -Path $target -Parent)
            Copy-Item -Path $_.FullName -Destination $target -Force
        }
    }
}


function Invoke-CollectArtifacts {
    param(
        [Parameter(Mandatory = $true)]$Project,
        [Parameter(Mandatory = $true)][string]$ProjectDir,
        [Parameter(Mandatory = $true)][string]$OutputDir
    )

    $targets = @($Project.collect.targets)
    if ($targets.Count -eq 0) { throw "collect.targets 不能为空 (project=$($Project.id))" }

    foreach ($t in $targets) {
        if ([string]::IsNullOrWhiteSpace($t.source)) { throw "collect.targets.source 不能为空 (project=$($Project.id))" }
        $src = Join-Path $ProjectDir $t.source

        $destRelative = if ($t.destination) { $t.destination } else { $Project.id }
        $dest = Join-Path $OutputDir $destRelative

        if ($t.cleanDestination -ne $false -and (Test-Path $dest)) {
            Remove-Item -Path $dest -Recurse -Force
        }

        Copy-WithExclude -Source $src -Destination $dest -Exclude @($t.exclude)
    }
}

function Invoke-ProjectBuildPipeline {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Project, [Parameter(Mandatory = $true)]$Context)

    $ctx = [PSCustomObject]@{
        stage = 'build'
        projectId = $Project.id
        logDir = $Context.logDir
        workspaceDir = $Context.workspaceDir
        outputDir = $Context.outputDir
    }

    $buildHooks = Get-OptionalProperty -Object $Config.stages.build -Name 'hooks'
    $projectHooks = Get-OptionalProperty -Object $Project -Name 'hooks'
    Invoke-Hook -Hook (Get-OptionalProperty -Object $buildHooks -Name 'before') -Context $ctx -WorkDir $PSScriptRoot
    Invoke-Hook -Hook (Get-OptionalProperty -Object $projectHooks -Name 'before') -Context $ctx -WorkDir $PSScriptRoot

    $projectDir = Sync-ProjectRepo -Config $Config -Project $Project
    Invoke-ProjectBuildTool -Config $Config -Project $Project -ProjectDir $projectDir
    Invoke-CollectArtifacts -Project $Project -ProjectDir $projectDir -OutputDir $Context.outputDir

    $commit = Get-ProjectCommitId -Config $Config -ProjectDir $projectDir
    $Context.projectCommits[$Project.id] = $commit

    Invoke-Hook -Hook (Get-OptionalProperty -Object $projectHooks -Name 'after') -Context $ctx -WorkDir $PSScriptRoot
    Invoke-Hook -Hook (Get-OptionalProperty -Object $buildHooks -Name 'after') -Context $ctx -WorkDir $PSScriptRoot
}

function Invoke-BuildStage {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][string]$ConfigPath)

    if (-not $Config.stages.build.enabled) { Write-Log -Message 'build 阶段已禁用'; return }

    $projectIds = @($Config.stages.build.projects)
    $targets = if ($projectIds.Count -gt 0) { @($Config.projects | Where-Object { $projectIds -contains $_.id }) } else { @($Config.projects) }

    $parallel = [bool]$Config.stages.build.parallel.enabled
    $maxWorkers = if ($Config.stages.build.parallel.maxWorkers) { [int]$Config.stages.build.parallel.maxWorkers } else { 2 }

    if ($parallel -and $targets.Count -gt 1) {
        Write-Log -Message "build 并行启用: $maxWorkers"
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $targets | ForEach-Object { $queue.Enqueue($_) }
        $running = @()

        while ($queue.Count -gt 0 -or $running.Count -gt 0) {
            while ($queue.Count -gt 0 -and $running.Count -lt $maxWorkers) {
                $proj = $queue.Dequeue()
                $job = Start-Job -ScriptBlock {
                    param($root, $cfg, $projectId)
                    & (Join-Path $root 'build-project.ps1') -ConfigPath $cfg -ProjectId $projectId
                } -ArgumentList $PSScriptRoot, $ConfigPath, $proj.id
                $running += $job
                Write-Log -Message "并行启动项目: $($proj.id) (JobId=$($job.Id))"
            }

            $done = @($running | Where-Object { $_.State -in @('Completed','Failed','Stopped') })
            foreach ($job in $done) {
                $out = Receive-Job -Job $job -Keep
                foreach ($line in $out) { Write-Log -Message "$line" }
                if ($job.State -ne 'Completed') { throw "并行任务失败(JobId=$($job.Id), State=$($job.State))" }
                Remove-Job -Job $job | Out-Null
                $running = @($running | Where-Object { $_.Id -ne $job.Id })
            }
            Start-Sleep -Milliseconds 500
        }

        # 并行模式下重新收集 commitId
        foreach ($p in $targets) {
            $dir = Join-Path $Context.workspaceDir $p.source.dir
            if (Test-Path $dir) { $Context.projectCommits[$p.id] = Get-ProjectCommitId -Config $Config -ProjectDir $dir }
        }
    }
    else {
        foreach ($p in $targets) {
            Write-Log -Message "构建项目: $($p.id)"
            Invoke-ProjectBuildPipeline -Config $Config -Project $p -Context $Context
        }
    }
}

function Bump-Version {
    param([Parameter(Mandatory = $true)][string]$Current, [Parameter(Mandatory = $true)][string]$Mode)
    if ([string]::IsNullOrWhiteSpace($Current)) { $Current = '0.1.0' }
    if ($Current -notmatch '^(\d+)\.(\d+)\.(\d+)$') { throw "版本格式必须为 x.y.z, 当前: $Current" }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
    switch ($Mode) {
        'major' { $major += 1; $minor = 0; $patch = 0 }
        'minor' { $minor += 1; $patch = 0 }
        'patch' { $patch += 1 }
        'none' { }
        default { throw "不支持的版本升级模式: $Mode" }
    }
    return "$major.$minor.$patch"
}


function Get-ReleaseArchiveName {
    param([Parameter(Mandatory = $true)]$Config)

    $pkg = $Config.stages.release.package
    if ($pkg.name -and -not [string]::IsNullOrWhiteSpace($pkg.name)) {
        return $pkg.name
    }

    $productName = if ($pkg.productName) { $pkg.productName } else { 'product' }
    $now = Get-Date
    $yy = $now.ToString('yy')
    $quarter = [math]::Ceiling($now.Month / 3)
    $date = $now.ToString('yyyyMMdd')
    return "{0}_{1}R{2}_{3}.7z" -f $productName, $yy, $quarter, $date
}


function Normalize-InnoSliceSize {
    param([string]$SliceSize)

    if ([string]::IsNullOrWhiteSpace($SliceSize)) { return '4096M' }

    if ($SliceSize -match '^(\d+)([KkMmGg])$') {
        $n = [int]$Matches[1]
        $u = $Matches[2].ToUpperInvariant()

        if ($u -eq 'G' -and $n -gt 4) { return '4096M' }
        if ($u -eq 'M' -and $n -gt 4096) { return '4096M' }
        if ($u -eq 'K' -and $n -gt 4194304) { return '4096M' }
        return ("{0}{1}" -f $n, $u)
    }

    return '4096M'
}

function New-InnoScript {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $inno = Get-OptionalProperty -Object $Config.stages.release.package -Name 'inno'
    if (-not $inno -or -not [bool]$inno.enabled) { return $null }

    $appName = if ($inno.appName) { $inno.appName } else { (Get-OptionalProperty -Object $Config.stages.release.package -Name 'productName') }
    if ([string]::IsNullOrWhiteSpace($appName)) { $appName = 'Product' }

    $publisher = if ($inno.publisher) { $inno.publisher } else { 'Unknown' }
    $appVersion = if ($Version) { $Version } else { '0.0.0' }
    $outputBaseName = if ($inno.outputBaseName) { $inno.outputBaseName } else { "{0}_setup" -f $BaseName }

    $slice = Normalize-InnoSliceSize -SliceSize $inno.maxDataPackageSize
    $dataModeRaw = if ($inno.dataMode) { [string]$inno.dataMode } else { 'external' }
    $dataMode = $dataModeRaw.Trim().ToLowerInvariant()
    if (@('external', 'embedded') -notcontains $dataMode) {
        throw "release.inno.dataMode 仅支持 external 或 embedded，当前值: $dataModeRaw"
    }
    $externalFlag = if ($dataMode -eq 'external') { ' external' } else { '' }

    $scriptPath = Join-Path $Context.packageDir ("{0}.iss" -f $outputBaseName)

    $templatePath = if ($inno.scriptTemplatePath) { [string]$inno.scriptTemplatePath } else { './inno/setup-template.iss' }
    $templatePath = $templatePath.Trim()
    if (-not [string]::IsNullOrWhiteSpace($templatePath) -and -not [System.IO.Path]::IsPathRooted($templatePath)) {
        $templatePath = Join-Path $PSScriptRoot $templatePath
    }
    if ([string]::IsNullOrWhiteSpace($templatePath) -or -not (Test-Path -Path $templatePath)) {
        throw "Inno 模板文件不存在: $templatePath"
    }

    $template = Get-Content -Path $templatePath -Raw
    $rendered = $template
        .Replace('{{APP_NAME}}', $appName)
        .Replace('{{APP_VERSION}}', $appVersion)
        .Replace('{{APP_PUBLISHER}}', $publisher)
        .Replace('{{DEFAULT_DIR_NAME}}', ('{autopf}\' + $appName))
        .Replace('{{OUTPUT_DIR}}', $Context.packageDir)
        .Replace('{{OUTPUT_BASE_FILENAME}}', $outputBaseName)
        .Replace('{{DISK_SLICE_SIZE}}', $slice)
        .Replace('{{SOURCE_DIR}}', $Context.outputDir)
        .Replace('{{EXTERNAL_FLAG}}', $externalFlag)
    $rendered | Set-Content -Path $scriptPath -Encoding UTF8

    return [PSCustomObject]@{ ScriptPath = $scriptPath; OutputBaseName = $outputBaseName }
}

function Invoke-InnoPackaging {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$BaseName
    )

    $inno = Get-OptionalProperty -Object $Config.stages.release.package -Name 'inno'
    if (-not $inno -or -not [bool]$inno.enabled) { return @() }

    $iscc = Resolve-Tool -Config $Config -ToolKey 'innoSetup' -Default 'iscc'
    $spec = New-InnoScript -Config $Config -Context $Context -Version $Version -BaseName $BaseName
    if (-not $spec) { return @() }

    Invoke-Command -Command $iscc -Args @($spec.ScriptPath)

    $files = @(
        Get-ChildItem -Path $Context.packageDir -File |
        Where-Object { $_.BaseName -eq $spec.OutputBaseName -or $_.Name -like ("{0}-*" -f $spec.OutputBaseName) } |
        ForEach-Object { $_.FullName }
    )

    return $files
}

function Invoke-ReleaseStage {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Context)

    if (-not $Config.stages.release.enabled) { Write-Log -Message 'release 阶段已禁用'; return }

    $ctx = [PSCustomObject]@{ stage = 'release'; logDir = $Context.logDir; outputDir = $Context.outputDir; packageDir = $Context.packageDir }
    $releaseHooks = Get-OptionalProperty -Object $Config.stages.release -Name 'hooks'
    Invoke-Hook -Hook (Get-OptionalProperty -Object $releaseHooks -Name 'before') -Context $ctx -WorkDir $PSScriptRoot

    Ensure-Directory -Path $Context.outputDir
    Ensure-Directory -Path $Context.packageDir

    $nextVersion = Bump-Version -Current $Config.parameters.version.current -Mode $Config.stages.release.version.bump
    $Context.version = $nextVersion

    $buildInfo = [PSCustomObject]@{
        version = $nextVersion
        buildTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
        commitIds = $Context.projectCommits
    }
    $buildInfoFile = Join-Path $Context.outputDir 'buildInfo.json'
    $buildInfo | ConvertTo-Json -Depth 50 | Set-Content -Path $buildInfoFile -Encoding UTF8
    Write-Log -Message "生成 buildInfo: $buildInfoFile"

    $zip = Resolve-Tool -Config $Config -ToolKey 'sevenZip' -Default '7z'
    $archiveName = Get-ReleaseArchiveName -Config $Config
    $archivePath = Join-Path $Context.packageDir $archiveName

    $args = @('a', '-t7z')
    if ($Config.stages.release.package.volumeSize) { $args += "-v$($Config.stages.release.package.volumeSize)" }
    foreach ($ex in @($Config.stages.release.package.exclude)) {
        if ($ex) { $args += "-xr!$ex" }
    }
    $args += @($archivePath, (Join-Path $Context.outputDir '*'))
    Invoke-Command -Command $zip -Args $args

    $basePattern = [System.IO.Path]::GetFileNameWithoutExtension($archiveName)
    $allPackages = @(
        Get-ChildItem -Path $Context.packageDir -File |
        Where-Object { $_.Name -like "$basePattern*" -and $_.Name -notlike '*.sha256' } |
        ForEach-Object { $_.FullName }
    )

    if ($allPackages.Count -eq 0 -and (Test-Path $archivePath)) { $allPackages = @($archivePath) }

    $innoPackages = Invoke-InnoPackaging -Config $Config -Context $Context -Version $nextVersion -BaseName $basePattern
    if ($innoPackages.Count -gt 0) {
        foreach ($f in $innoPackages) {
            if ($allPackages -notcontains $f) { $allPackages += $f }
        }
    }

    $shaFile = Join-Path $Context.packageDir ("{0}.sha256" -f $basePattern)
    $shaLines = @()
    foreach ($pkg in $allPackages) {
        $hash = (Get-FileHash -Path $pkg -Algorithm SHA256).Hash.ToLowerInvariant()
        $shaLines += ("{0}  {1}" -f $hash, [System.IO.Path]::GetFileName($pkg))
    }
    $shaLines | Set-Content -Path $shaFile -Encoding ASCII

    $Context.packageFiles = $allPackages
    $Context.shaFile = $shaFile
    Write-Log -Message "生成 SHA256: $shaFile"

    Invoke-Hook -Hook (Get-OptionalProperty -Object $releaseHooks -Name 'after') -Context $ctx -WorkDir $PSScriptRoot
}

function Upload-FtpFile {
    param([Parameter(Mandatory = $true)]$Ftp, [Parameter(Mandatory = $true)][string]$LocalFile)
    $url = $Ftp.url.TrimEnd('/') + '/' + [System.IO.Path]::GetFileName($LocalFile)
    Write-Log -Message "FTP 上传: $url"
    $req = [System.Net.FtpWebRequest]::Create($url)
    $req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    $req.Credentials = New-Object System.Net.NetworkCredential($Ftp.username, $Ftp.password)
    $bytes = [System.IO.File]::ReadAllBytes($LocalFile)
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Close() }
    $resp = $req.GetResponse()
    try { Write-Log -Message "FTP 完成: $($resp.StatusDescription)" } finally { $resp.Close() }
}

function Invoke-UploadStage {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Context)

    if (-not $Config.stages.upload.enabled) { Write-Log -Message 'upload 阶段已禁用'; return }

    $ctx = [PSCustomObject]@{ stage = 'upload'; logDir = $Context.logDir; packageDir = $Context.packageDir }
    $uploadHooks = Get-OptionalProperty -Object $Config.stages.upload -Name 'hooks'
    Invoke-Hook -Hook (Get-OptionalProperty -Object $uploadHooks -Name 'before') -Context $ctx -WorkDir $PSScriptRoot

    $ftp = Get-OptionalProperty -Object $Config.stages.upload -Name 'ftp'
    if (-not $ftp) { throw 'upload.ftp 未配置' }
    if ([string]::IsNullOrWhiteSpace($ftp.url)) { throw 'upload.ftp.url 不能为空' }
    if ([string]::IsNullOrWhiteSpace($ftp.username)) { throw 'upload.ftp.username 不能为空' }
    if ([string]::IsNullOrWhiteSpace($ftp.password)) { throw 'upload.ftp.password 不能为空' }

    foreach ($file in @($Context.packageFiles)) { Upload-FtpFile -Ftp $ftp -LocalFile $file }
    if ($Config.stages.upload.uploadSha256 -and $Context.shaFile -and (Test-Path $Context.shaFile)) {
        Upload-FtpFile -Ftp $ftp -LocalFile $Context.shaFile
    }

    Invoke-Hook -Hook (Get-OptionalProperty -Object $uploadHooks -Name 'after') -Context $ctx -WorkDir $PSScriptRoot
}
