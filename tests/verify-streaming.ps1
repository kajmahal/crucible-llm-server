$http = Get-Content "$PSScriptRoot\..\llama.swiftui\HTTPServer.swift" -Raw
$state = Get-Content "$PSScriptRoot\..\llama.swiftui\Models\LlamaState.swift" -Raw
$checks = @(
    @{ Name='stream request flag'; Text='let stream = json["stream"] as? Bool ?? false'; Source=$http },
    @{ Name='SSE content type'; Text='text/event-stream'; Source=$http },
    @{ Name='OpenAI chunk object'; Text='chat.completion.chunk'; Source=$http },
    @{ Name='DONE sentinel'; Text='data: [DONE]'; Source=$http },
    @{ Name='streaming generation method'; Text='completeForAPIStreaming'; Source=$state },
    @{ Name='shared output cleaner'; Text='cleanAPIOutput'; Source=$state }
)
$missing = @($checks | Where-Object { -not $_.Source.Contains($_.Text) } | ForEach-Object Name)
if ($missing.Count) {
    Write-Error ("Missing streaming behavior:`n" + ($missing -join "`n"))
    exit 1
}
Write-Host 'OpenAI SSE streaming source checks verified.'