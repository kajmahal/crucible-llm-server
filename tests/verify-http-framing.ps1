$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\llama.swiftui\HTTPServer.swift'
$src = Get-Content -Raw -LiteralPath $path
$required = @(
  'Content-Length',
  'accumulatedData',
  'receiveCompleteRequest',
  'headerEnd',
  'expectedBodyLength'
)
$missing = @()
foreach ($token in $required) {
  if (-not $src.Contains($token)) { $missing += $token }
}
if ($src.Contains('connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in') -and -not $src.Contains('receiveCompleteRequest')) {
  $missing += 'one-shot receive replaced'
}
if ($missing.Count -gt 0) {
  throw ('HTTP framing regression: missing ' + ($missing -join ', '))
}
Write-Output 'HTTP request framing source checks verified.'