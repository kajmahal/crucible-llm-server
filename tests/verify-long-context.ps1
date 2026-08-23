$src = Get-Content "$PSScriptRoot\..\llama.cpp.swift\LibLlama.swift" -Raw
$checks = @(
    'let promptBatchSize = 512',
    'while chunkStart < tokens_list.count',
    'let chunkEnd = min(chunkStart + promptBatchSize, tokens_list.count)',
    'n_cur = Int32(tokens_list.count)'
)
$missing = @($checks | Where-Object { -not $src.Contains($_) })
if ($missing.Count) {
    Write-Error ("Missing chunked long-context prompt ingestion:`n" + ($missing -join "`n"))
    exit 1
}
Write-Host 'Long-context prompt batching verified.'