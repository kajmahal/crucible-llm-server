$src = Get-Content "$PSScriptRoot\..\llama.cpp.swift\LibLlama.swift" -Raw
$required = @(
    'sparams.no_perf = true',
    'ctx_params.no_perf = true'
)
$missing = @($required | Where-Object { -not $src.Contains($_) })
$forbidden = @(
    'print(new_token_str)',
    'for id in tokens_list {'
)
$present = @($forbidden | Where-Object { $src.Contains($_) })
if ($missing.Count -or $present.Count) {
    if ($missing.Count) { Write-Error ("Missing fast-path settings:`n" + ($missing -join "`n")) }
    if ($present.Count) { Write-Error ("Debug hot-path logging still present:`n" + ($present -join "`n")) }
    exit 1
}
Write-Host 'Metal inference fast path verified.'