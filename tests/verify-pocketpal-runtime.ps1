$src = Get-Content "$PSScriptRoot\..\llama.cpp.swift\LibLlama.swift" -Raw
$checks = @(
    'var n_len: Int32 = 8192',
    'model_params.n_gpu_layers = -1',
    'model_params.use_mmap = true',
    'model_params.use_mlock = false',
    'ctx_params.n_ctx = 8192',
    'ctx_params.n_batch = 512',
    'ctx_params.n_ubatch = 256',
    'ctx_params.n_threads = 4',
    'ctx_params.n_threads_batch = 4',
    'ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED',
    'ctx_params.type_k = GGML_TYPE_Q8_0',
    'ctx_params.type_v = GGML_TYPE_Q8_0',
    'ctx_params.offload_kqv = true',
    'ctx_params.op_offload = true'
)
$missing = @($checks | Where-Object { -not $src.Contains($_) })
if ($missing.Count) {
    Write-Error ("Missing optimized runtime settings:`n" + ($missing -join "`n"))
    exit 1
}
Write-Host '8K Metal runtime settings verified.'