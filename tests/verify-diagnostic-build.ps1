$root = Resolve-Path "$PSScriptRoot\.."
$http = Get-Content "$root\llama.swiftui\HTTPServer.swift" -Raw
$proj = Get-Content "$root\llama.swiftui.xcodeproj\project.pbxproj" -Raw
$workflow = Get-Content "$root\.github\workflows\build.yml" -Raw
$checks = @(
    @{ Name='version route'; Ok=$http.Contains('case "/version":') },
    @{ Name='git fingerprint'; Ok=$http.Contains('CrucibleGitCommit') },
    @{ Name='8k fingerprint'; Ok=$http.Contains('"context": 8192') },
    @{ Name='streaming fingerprint'; Ok=$http.Contains('"streaming": true') },
    @{ Name='runtime fingerprint'; Ok=$http.Contains('"runtime": "8k-metal-sse-http-framing"') },
    @{ Name='build number 3'; Ok=([regex]::Matches($proj,'CURRENT_PROJECT_VERSION = 3;').Count -eq 2) },
    @{ Name='marketing 1.2'; Ok=([regex]::Matches($proj,'MARKETING_VERSION = 1.2;').Count -eq 2) },
    @{ Name='Git SHA injected'; Ok=$workflow.Contains('INFOPLIST_KEY_CrucibleGitCommit="$GITHUB_SHA"') }
)
$missing = @($checks | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
if ($missing.Count) { Write-Error ('Missing diagnostic build behavior: ' + ($missing -join ', ')); exit 1 }
Write-Host 'Diagnostic build fingerprint verified.'