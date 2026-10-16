package sandboxrunner

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	qnsandbox "github.com/qiniu/go-sdk/v7/sandbox"
)

func TestPlatformForLabels(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		labels []string
		want   Platform
	}{
		{nil, PlatformLinux},
		{[]string{"self-hosted", "linux", "x64"}, PlatformLinux},
		{[]string{"self-hosted", "windows-11"}, PlatformLinux},
		{[]string{"self-hosted", " Windows ", "x64"}, PlatformWindows},
		{[]string{"qiniu", "windows"}, PlatformWindows},
	} {
		if got := PlatformForLabels(tt.labels); got != tt.want {
			t.Errorf("PlatformForLabels(%q) = %q, want %q", tt.labels, got, tt.want)
		}
	}
}

func TestWindowsRunnerBootstrapUsesEnvdDefaultUser(t *testing.T) {
	t.Parallel()
	if got := PlatformWindows.bootstrapUser(); got != qnsandbox.DefaultUser {
		t.Fatalf("Windows bootstrap user = %q, want %q", got, qnsandbox.DefaultUser)
	}
	if got := PlatformLinux.bootstrapUser(); got != runnerBootstrapUser {
		t.Fatalf("Linux bootstrap user = %q, want %q", got, runnerBootstrapUser)
	}
	if got := Platform("").bootstrapUser(); got != runnerBootstrapUser {
		t.Fatalf("unspecified platform bootstrap user = %q, want %q", got, runnerBootstrapUser)
	}
}

func TestWindowsStartScriptEncodesEveryArgument(t *testing.T) {
	t.Parallel()
	input := StartInput{
		Platform:            PlatformWindows,
		RequestID:           `req'$(calc)`,
		RepositoryURL:       `https://github.com/o/r'; calc; '`,
		RegistrationToken:   `tok"&calc`,
		RunnerName:          "runner`calc",
		Labels:              []string{"self-hosted", "windows", `x64'$(calc)`},
		RunnerGroup:         `group';calc;'`,
		CacheS3Region:       "cn-east-1",
		CacheS3Bucket:       "bucket'",
		CacheS3Endpoint:     "https://s3.example",
		CacheS3ReadPrefixes: "a,b",
		CacheS3WritePrefix:  "w",
		CacheS3AccessKeyID:  "ak'",
		CacheS3SecretKey:    "sk'",
		CacheS3SessionToken: "st'",
	}
	sandboxID := `sandbox'$(calc)`
	script := windowsStartScript(input, sandboxID)

	if strings.Contains(script, "%!") {
		t.Fatalf("script has formatting artifacts:\n%s", script)
	}
	if strings.Contains(script, "%[") {
		t.Fatalf("script has unsubstituted placeholders:\n%s", script)
	}
	for _, char := range script {
		if char > 0x7f {
			t.Fatalf("script contains non-ASCII character %q", char)
		}
	}
	for _, raw := range []string{
		input.RequestID,
		input.RepositoryURL,
		input.RegistrationToken,
		input.RunnerName,
		strings.Join(input.Labels, ","),
		input.RunnerGroup,
		input.CacheS3Bucket,
		input.CacheS3AccessKeyID,
		input.CacheS3SecretKey,
		input.CacheS3SessionToken,
		sandboxID,
	} {
		if strings.Contains(script, raw) {
			t.Fatalf("script contains raw argument %q", raw)
		}
		if !strings.Contains(script, "Decode-Argument '"+base64.StdEncoding.EncodeToString([]byte(raw))+"'") {
			t.Fatalf("script does not decode encoded argument %q", raw)
		}
	}
	if !strings.Contains(script, "if ('0' -eq '1')") {
		t.Fatal("script does not render the Docker requirement flag")
	}
}

func TestWindowsStartScriptUsesEphemeralRunnerAndHooks(t *testing.T) {
	t.Parallel()
	script := windowsStartScript(StartInput{Platform: PlatformWindows}, "sandbox-1")
	for _, want := range []string{
		"'--ephemeral', '--unattended', '--replace'",
		"'--runnergroup', $runnerGroup",
		"$env:ACTIONS_RUNNER_HOOK_JOB_STARTED = Join-Path $hookRoot 'job-started.ps1'",
		"$env:ACTIONS_RUNNER_HOOK_JOB_COMPLETED = Join-Path $hookRoot 'job-completed.ps1'",
		`RUNNERD_EFFECTIVE_RUNNER_VERSION=`,
		`RUNNERD_JOB_STARTED`,
		"& $runnerConfig remove --token $registrationToken",
		"Get-FileHash -LiteralPath $runnerUpdateArchive -Algorithm SHA256",
		"--max-filesize 536870912",
	} {
		if !strings.Contains(script, want) {
			t.Fatalf("script does not contain %q", want)
		}
	}
}

func TestRunnerApplicationsManifestFiltersByPlatform(t *testing.T) {
	t.Parallel()
	applications := []RunnerApplication{
		{
			Architecture:   "x64",
			Version:        "2.337.0",
			DownloadURL:    "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-x64-2.337.0.tar.gz",
			SHA256Checksum: "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613",
		},
		{
			OS:             "win",
			Architecture:   "x64",
			Version:        "2.337.0",
			DownloadURL:    "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-win-x64-2.337.0.zip",
			SHA256Checksum: "1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc",
		},
	}
	linux := runnerApplicationsManifest(PlatformLinux, applications)
	if linux != "x64\t2.337.0\t"+applications[0].DownloadURL+"\t"+applications[0].SHA256Checksum {
		t.Fatalf("Linux manifest = %q", linux)
	}
	windows := runnerApplicationsManifest(PlatformWindows, applications)
	if windows != "x64\t2.337.0\t"+applications[1].DownloadURL+"\t"+applications[1].SHA256Checksum {
		t.Fatalf("Windows manifest = %q", windows)
	}
	if got := runnerApplicationsManifest("", applications); got != linux {
		t.Fatalf("unspecified platform manifest = %q, want Linux manifest", got)
	}
}

func TestWindowsRuntimeEnvironmentCommandAvoidsCmdMetacharacters(t *testing.T) {
	t.Parallel()
	// cmd.exe expands %VAR% even inside quotes, and an embedded quote would end
	// the -Command argument early.
	body := strings.TrimSuffix(strings.SplitN(windowsRuntimeEnvironmentCommand, `-Command "`, 2)[1], `"`)
	if strings.ContainsAny(body, `%"`) {
		t.Fatalf("Windows runtime environment command contains cmd metacharacters: %s", body)
	}
}

func TestWindowsTemplateBuildCopiesReviewedInputs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	argsFile := filepath.Join(root, "args")
	stagedFile := filepath.Join(root, "staged")
	fakeKodoctl := filepath.Join(root, "kodoctl")
	writeExecutable(t, fakeKodoctl, `#!/usr/bin/env bash
printf '%s\n' "$@" >"`+argsFile+`"
find qiniu-build -type f | sort >"`+stagedFile+`"
cat qiniu-build/build.env >>"`+stagedFile+`"
`)
	output, err := runCommand(t, "bash", []string{"scripts/build-windows-template.sh", "templates/github-runner-windows-11"}, "KODOCTL="+fakeKodoctl, "KODOCTL_CONTEXT=test/ctx")
	if err != nil {
		t.Fatalf("build helper: %v: %s", err, output)
	}
	args, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"-c\ntest/ctx\nsbx\ntpl\nbuild\n",
		"--name\ngithub-runner-windows-11\n",
		"--os-platform\nwindows\n",
		"--from-disk-image\nfile:///home/qboxserver/qiniu/cloud-hypervisor/windows-11-25h2.compressed.qcow2\n",
		"--copy\nqiniu-build:C:\\qiniu-build\n",
		"-File C:\\qiniu-build\\setup-template.ps1 -BuildEnvironmentFile C:\\qiniu-build\\build.env\n",
		"--run-cmd\nrmdir /s /q C:\\qiniu-build\n",
	} {
		if !strings.Contains(string(args), want) {
			t.Fatalf("kodoctl args do not contain %q:\n%s", want, args)
		}
	}
	staged, err := os.ReadFile(stagedFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(staged), "qiniu-build/build.env\nqiniu-build/setup-template.ps1\nTEMPLATE_NAME=") || strings.Contains(string(staged), "#") {
		t.Fatalf("staged build inputs = %s", staged)
	}
}

func TestWindowsTemplateRunnerPinMatchesCommonPin(t *testing.T) {
	t.Parallel()
	read := func(path, key string) string {
		t.Helper()
		content, err := os.ReadFile(filepath.Join(repositoryRoot(t), path))
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(content), "\n") {
			if value, ok := strings.CutPrefix(line, key+"="); ok {
				return value
			}
		}
		t.Fatalf("%s has no %s", path, key)
		return ""
	}
	common := read("templates/common/actions-runner.env", "RUNNER_VERSION")
	windows := read("templates/github-runner-windows-11/template.env", "RUNNER_WIN_X64_VERSION")
	if windows != common {
		t.Fatalf("Windows runner pin %s does not match common pin %s; update template.env with the win-x64 archive digest and size", windows, common)
	}
}
