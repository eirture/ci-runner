$ErrorActionPreference = 'Stop'
# Invoke-WebRequest and Expand-Archive progress bars need a console buffer,
# which processes started by envd do not have.
$ProgressPreference = 'SilentlyContinue'

function Decode-Argument([string]$value) {
  if ([string]::IsNullOrEmpty($value)) {
    return ''
  }
  return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
}

function Get-RunnerVersion([string]$root) {
  $listener = Join-Path $root 'bin\Runner.Listener.exe'
  if (-not (Test-Path -LiteralPath $listener -PathType Leaf)) {
    return ''
  }
  try {
    return ((& $listener --version 2>$null) | Out-String).Trim()
  } catch {
    return ''
  }
}

function Test-RunnerVersionAtLeast([string]$current, [string]$target) {
  if ($current -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
    return $false
  }
  $currentComponents = $current.Split('.')
  $targetComponents = $target.Split('.')
  for ($index = 0; $index -lt 3; $index++) {
    $currentComponent = $currentComponents[$index].TrimStart('0')
    $targetComponent = $targetComponents[$index].TrimStart('0')
    if ($currentComponent.Length -ne $targetComponent.Length) {
      return $currentComponent.Length -gt $targetComponent.Length
    }
    $comparison = [string]::CompareOrdinal($currentComponent, $targetComponent)
    if ($comparison -ne 0) {
      return $comparison -gt 0
    }
  }
  return $true
}

function Fail([string]$message, [int]$code = 1) {
  [Console]::Error.WriteLine($message)
  exit $code
}

# Templates are memory snapshots, so envd keeps the environment it had before
# template setup. Reload the persisted machine and user values.
foreach ($scope in @('Machine', 'User')) {
  $persisted = [Environment]::GetEnvironmentVariables($scope)
  foreach ($name in $persisted.Keys) {
    if ($name -ne 'Path') {
      [Environment]::SetEnvironmentVariable($name, [string]$persisted[$name], 'Process')
    }
  }
}
$env:Path = (@([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) | Where-Object { $_ }) -join ';'

$actionsRunnerRoot = if ($env:ACTIONS_RUNNER_ROOT) { $env:ACTIONS_RUNNER_ROOT } else { 'C:\actions-runner' }
$runnerRoot = if ($env:RUNNER_ROOT) { $env:RUNNER_ROOT } else { 'C:\runner' }
$workdir = Join-Path $runnerRoot 'actions-runner'
$runnerJobWork = Join-Path $runnerRoot 'work'
$hookRoot = Join-Path $runnerRoot '_runnerd-hooks'
$environmentFile = 'C:\ProgramData\qiniu-runner\image.env'
if (-not $env:RUNNER_TOOL_CACHE) { $env:RUNNER_TOOL_CACHE = 'C:\hostedtoolcache' }
if (-not $env:AGENT_TOOLSDIRECTORY) { $env:AGENT_TOOLSDIRECTORY = $env:RUNNER_TOOL_CACHE }
if (Test-Path -LiteralPath $environmentFile -PathType Leaf) {
  foreach ($line in Get-Content -LiteralPath $environmentFile) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      $value = $Matches[2].Trim()
      if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
        $value = $value.Substring(1, $value.Length - 2)
      }
      [Environment]::SetEnvironmentVariable($Matches[1], $value, 'Process')
    }
  }
}

foreach ($directory in @($runnerRoot, $workdir, $runnerJobWork, $hookRoot, $env:RUNNER_TOOL_CACHE)) {
  New-Item -ItemType Directory -Force -Path $directory | Out-Null
}
Set-Location -LiteralPath $workdir

$runnerConfig = Join-Path $workdir 'config.cmd'
if (-not (Test-Path -LiteralPath $runnerConfig -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $actionsRunnerRoot 'config.cmd') -PathType Leaf)) {
  Write-Output 'copying preinstalled GitHub Actions runner'
  Copy-Item -Path (Join-Path $actionsRunnerRoot '*') -Destination $workdir -Recurse -Force
}

$runnerApplicationsManifest = Decode-Argument '%[17]s'
if ($runnerApplicationsManifest) {
  $runnerArchitecture = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { Fail "unsupported architecture for GitHub Actions runner preflight update: $($env:PROCESSOR_ARCHITECTURE)" }
  }
  $runnerTargetVersion = ''
  $runnerDownloadURL = ''
  $runnerSHA256Checksum = ''
  foreach ($line in $runnerApplicationsManifest -split "`n") {
    $fields = $line.Split("`t")
    if ($fields.Length -eq 4 -and $fields[0] -eq $runnerArchitecture) {
      $runnerTargetVersion = $fields[1]
      $runnerDownloadURL = $fields[2]
      $runnerSHA256Checksum = $fields[3]
      break
    }
  }
  if (-not $runnerTargetVersion -or -not $runnerDownloadURL -or -not $runnerSHA256Checksum) {
    Fail "GitHub Actions runner preflight update has no application for architecture $runnerArchitecture"
  }

  $currentRunnerVersion = Get-RunnerVersion $workdir
  if ($currentRunnerVersion -eq $runnerTargetVersion) {
    Write-Output "GitHub Actions runner $runnerTargetVersion is already installed"
  } elseif (Test-RunnerVersionAtLeast $currentRunnerVersion $runnerTargetVersion) {
    Write-Output "GitHub Actions runner $currentRunnerVersion is newer than target $runnerTargetVersion; keeping installed version"
  } else {
    $runnerUpdateRoot = Join-Path $runnerRoot ('actions-runner.update.' + [Guid]::NewGuid().ToString('N'))
    $runnerUpdateArchive = Join-Path $runnerUpdateRoot 'runner.zip'
    $runnerUpdateCandidate = Join-Path $runnerUpdateRoot 'candidate'
    $runnerPreviousWorkdir = Join-Path $runnerUpdateRoot 'previous'
    $keepRunnerUpdateRoot = $false
    New-Item -ItemType Directory -Force -Path $runnerUpdateCandidate | Out-Null
    try {
      Write-Output "downloading GitHub Actions runner $runnerTargetVersion for $runnerArchitecture"
      # curl.exe ships with Windows 11 and bounds the transfer size and time.
      & curl.exe --fail --location --silent --show-error --retry 3 --retry-delay 1 --retry-max-time 300 --connect-timeout 10 --max-time 300 --max-filesize 536870912 --output $runnerUpdateArchive $runnerDownloadURL
      if ($LASTEXITCODE -ne 0) {
        Fail 'GitHub Actions runner download failed'
      }
      $archiveChecksum = (Get-FileHash -LiteralPath $runnerUpdateArchive -Algorithm SHA256).Hash.ToLowerInvariant()
      if ($archiveChecksum -ne $runnerSHA256Checksum) {
        Fail 'GitHub Actions runner archive checksum verification failed'
      }
      try {
        Expand-Archive -LiteralPath $runnerUpdateArchive -DestinationPath $runnerUpdateCandidate -Force
      } catch {
        Fail 'GitHub Actions runner archive extraction failed'
      }
      $candidateRunnerVersion = Get-RunnerVersion $runnerUpdateCandidate
      if ($candidateRunnerVersion -ne $runnerTargetVersion) {
        $observedRunnerVersion = if ($candidateRunnerVersion) { $candidateRunnerVersion } else { 'unknown' }
        Fail "GitHub Actions runner archive version verification failed: got $observedRunnerVersion, want $runnerTargetVersion"
      }

      Set-Location -LiteralPath $runnerRoot
      try {
        Move-Item -LiteralPath $workdir -Destination $runnerPreviousWorkdir
      } catch {
        Fail 'GitHub Actions runner work directory replacement failed'
      }
      try {
        Move-Item -LiteralPath $runnerUpdateCandidate -Destination $workdir
      } catch {
        try {
          Move-Item -LiteralPath $runnerPreviousWorkdir -Destination $workdir
        } catch {
          # The previous Runner is the last recoverable copy. Keep the update root.
          $keepRunnerUpdateRoot = $true
          [Console]::Error.WriteLine("GitHub Actions runner work directory rollback failed: $runnerPreviousWorkdir")
        }
        Fail 'GitHub Actions runner work directory replacement failed'
      }
      $previousRunnerLabel = if ($currentRunnerVersion) { $currentRunnerVersion } else { 'unknown' }
      Write-Output "updated GitHub Actions runner from $previousRunnerLabel to $runnerTargetVersion"
    } finally {
      if (-not $keepRunnerUpdateRoot) {
        Remove-Item -LiteralPath $runnerUpdateRoot -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    Set-Location -LiteralPath $workdir
  }
}

if (-not (Test-Path -LiteralPath $runnerConfig -PathType Leaf)) {
  [Console]::Error.WriteLine("missing GitHub Actions runner at $actionsRunnerRoot\config.cmd")
  Fail 'use a Windows runner template with a preinstalled runner, or a private spec that resolves runner downloads'
}

if ('%[8]s' -eq '1') {
  Fail 'Docker daemon is required for this managed runner but Windows runners do not provide Docker'
}

$runnerURL = Decode-Argument '%[1]s'
$registrationToken = Decode-Argument '%[2]s'
$runnerName = Decode-Argument '%[3]s'
$runnerLabels = Decode-Argument '%[4]s'
$runnerGroup = Decode-Argument '%[5]s'
$runnerRequestID = Decode-Argument '%[6]s'
$sandboxID = Decode-Argument '%[7]s'
$cacheS3Region = Decode-Argument '%[9]s'
$cacheS3Bucket = Decode-Argument '%[10]s'
$cacheS3Endpoint = Decode-Argument '%[11]s'
$cacheS3ReadPrefixes = Decode-Argument '%[12]s'
$cacheS3WritePrefix = Decode-Argument '%[13]s'
$cacheS3AccessKey = Decode-Argument '%[14]s'
$cacheS3SecretKey = Decode-Argument '%[15]s'
$cacheS3SessionToken = Decode-Argument '%[16]s'

# Inject Cache S3 STS credentials for qiniu/actions-cache
if ($cacheS3Bucket -and $cacheS3AccessKey -and $cacheS3SecretKey) {
  $env:RUNS_ON_S3_BUCKET_CACHE = $cacheS3Bucket
  if ($cacheS3Endpoint) {
    $env:RUNS_ON_S3_BUCKET_ENDPOINT = $cacheS3Endpoint
  }
  $env:RUNS_ON_AWS_REGION = $cacheS3Region
  $env:RUNS_ON_S3_FORCE_PATH_STYLE = 'true'
  # qiniu/actions-cache reads these dedicated variables into an explicit S3
  # client provider, so workflow AWS credential changes cannot replace them.
  $env:RUNS_ON_S3_ACCESS_KEY_ID = $cacheS3AccessKey
  $env:RUNS_ON_S3_SECRET_ACCESS_KEY = $cacheS3SecretKey
  if ($cacheS3SessionToken) {
    $env:RUNS_ON_S3_SESSION_TOKEN = $cacheS3SessionToken
  }
  # Keep AWS-compatible names for SDKs used by workflow steps.
  $env:AWS_ACCESS_KEY_ID = $cacheS3AccessKey
  $env:AWS_SECRET_ACCESS_KEY = $cacheS3SecretKey
  if ($cacheS3SessionToken) {
    $env:AWS_SESSION_TOKEN = $cacheS3SessionToken
  }
  if ($cacheS3ReadPrefixes) {
    $env:RUNS_ON_S3_CACHE_READ_PREFIXES = $cacheS3ReadPrefixes
  } else {
    [Console]::Error.WriteLine('cache S3 read scopes are missing; restore is disabled')
  }
  if ($cacheS3WritePrefix) {
    $env:RUNS_ON_S3_CACHE_WRITE_PREFIX = $cacheS3WritePrefix
  } else {
    [Console]::Error.WriteLine('cache S3 write scope is missing; save is disabled')
  }
  # Tune qiniu/actions-cache upload/download concurrency for better throughput.
  if (-not $env:UPLOAD_QUEUE_SIZE) { $env:UPLOAD_QUEUE_SIZE = '16' }
  if (-not $env:UPLOAD_PART_SIZE) { $env:UPLOAD_PART_SIZE = '16' }
  if (-not $env:DOWNLOAD_QUEUE_SIZE) { $env:DOWNLOAD_QUEUE_SIZE = '16' }
  if (-not $env:DOWNLOAD_PART_SIZE) { $env:DOWNLOAD_PART_SIZE = '16' }
  Write-Output "injected cache S3 STS credentials for qiniu/actions-cache (upload_queue=$($env:UPLOAD_QUEUE_SIZE) upload_part=$($env:UPLOAD_PART_SIZE)MiB download_queue=$($env:DOWNLOAD_QUEUE_SIZE) download_part=$($env:DOWNLOAD_PART_SIZE)MiB)"
} elseif ($cacheS3Bucket) {
  [Console]::Error.WriteLine('cache S3 configuration is incomplete; skipping credential injection')
}

$env:RUNNERD_SANDBOX_ID = $sandboxID
$env:RUNNERD_REQUEST_ID = $runnerRequestID
$env:RUNNERD_RUNNER_NAME = $runnerName
$env:RUNNERD_RUNNER_LISTENER = Join-Path $workdir 'bin\Runner.Listener.exe'

# Windows has no FIFO. The job-started hook atomically publishes a marker file
# that this script relays to its own stdout, where runnerd observes it.
$hookSignalPath = Join-Path $hookRoot 'job-started.signal'
Remove-Item -LiteralPath $hookSignalPath, "$hookSignalPath.tmp" -Force -ErrorAction SilentlyContinue
$env:RUNNERD_HOOK_SIGNAL_FALLBACK_PATH = $hookSignalPath
Set-Content -LiteralPath (Join-Path $hookRoot 'job-started.ps1') -Encoding ASCII -Value @'
$effectiveRunnerVersion = ''
try {
  $effectiveRunnerVersion = ((& $env:RUNNERD_RUNNER_LISTENER --version 2>$null) | Out-String).Trim()
} catch {
}
$signal = ''
if ($effectiveRunnerVersion.Length -le 256 -and $effectiveRunnerVersion -match '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$') {
  $signal += "RUNNERD_EFFECTIVE_RUNNER_VERSION=$effectiveRunnerVersion`n"
}
$signal += "RUNNERD_JOB_STARTED`n"
if ($env:RUNNERD_HOOK_SIGNAL_FALLBACK_PATH) {
  $temporary = "$($env:RUNNERD_HOOK_SIGNAL_FALLBACK_PATH).tmp"
  [IO.File]::WriteAllText($temporary, $signal)
  Move-Item -LiteralPath $temporary -Destination $env:RUNNERD_HOOK_SIGNAL_FALLBACK_PATH -Force
}
Write-Output "::notice title=Qiniu sandbox::sandbox_id=$($env:RUNNERD_SANDBOX_ID) runner_request_id=$($env:RUNNERD_REQUEST_ID) runner_name=$($env:RUNNERD_RUNNER_NAME)"
Write-Output "Qiniu sandbox id: $($env:RUNNERD_SANDBOX_ID)"
Write-Output "Runner request id: $($env:RUNNERD_REQUEST_ID)"
Write-Output "Runner name: $($env:RUNNERD_RUNNER_NAME)"
'@
Set-Content -LiteralPath (Join-Path $hookRoot 'job-completed.ps1') -Encoding ASCII -Value @'
Write-Output 'RUNNERD_JOB_COMPLETED'
'@
$env:ACTIONS_RUNNER_HOOK_JOB_STARTED = Join-Path $hookRoot 'job-started.ps1'
$env:ACTIONS_RUNNER_HOOK_JOB_COMPLETED = Join-Path $hookRoot 'job-completed.ps1'

$configArguments = @('--url', $runnerURL, '--token', $registrationToken, '--name', $runnerName, '--labels', $runnerLabels, '--work', $runnerJobWork, '--ephemeral', '--unattended', '--replace')
if ($runnerGroup) {
  $configArguments += @('--runnergroup', $runnerGroup)
}

Write-Output "configuring GitHub Actions runner $runnerName"
$retriesLeft = 10
while ($true) {
  & $runnerConfig @configArguments
  if ($LASTEXITCODE -eq 0) {
    break
  }
  $retriesLeft--
  if ($retriesLeft -eq 0) {
    Fail 'GitHub Actions runner configuration failed' 2
  }
  Write-Output 'GitHub Actions runner configuration failed, retrying'
  Start-Sleep -Seconds 1
}

$runnerExitCode = 1
try {
  Write-Output 'starting GitHub Actions runner'
  # The runner inherits this process's stdout, so its output streams to runnerd
  # while this loop relays the job-started marker.
  $runner = Start-Process -FilePath (Join-Path $workdir 'run.cmd') -WorkingDirectory $workdir -NoNewWindow -PassThru
  # Cache the process handle so ExitCode stays available after exit.
  $null = $runner.Handle
  $hookSignalRelayed = $false
  while (-not $runner.HasExited) {
    if (-not $hookSignalRelayed -and (Test-Path -LiteralPath $hookSignalPath -PathType Leaf)) {
      [Console]::Out.Write([IO.File]::ReadAllText($hookSignalPath))
      [Console]::Out.Flush()
      Remove-Item -LiteralPath $hookSignalPath -Force -ErrorAction SilentlyContinue
      $hookSignalRelayed = $true
    }
    Start-Sleep -Milliseconds 100
  }
  $runner.WaitForExit()
  $runnerExitCode = $runner.ExitCode
} finally {
  Remove-Item -LiteralPath $hookSignalPath, "$hookSignalPath.tmp" -Force -ErrorAction SilentlyContinue
  & $runnerConfig remove --token $registrationToken
}
exit $runnerExitCode
