param(
    [string]$Python = 'D:\miniconda\miniconda\envs\SWPC_ENV\python.exe'
)

$ErrorActionPreference = 'Stop'
$caseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "Python interpreter not found: $Python"
}

$commands = @(
    @('.\golden\test_style_pipeline.py'),
    @('.\golden\test_r1_isp.py'),
    @('.\golden\test_descriptor_format.py'),
    @('.\golden\test_frame_buffer_format.py'),
    @('.\model\test_microstyle_layout.py'),
    @('.\model\test_microstyle_schedule.py'),
    @('.\model\test_microstyle_qat.py'),
    @('.\model\validate_microstyle_qat.py', '--device', 'cpu', '--size', '64'),
    @('.\model\microstyle_model.py', '--smoke-width', '64', '--smoke-height', '48'),
    @('.\model\microstyle_layout.py', '--output-dir', '.\model\microstyle24_untrained'),
    @('.\golden\validate_r1_natural_images.py'),
    @('.\model\test_tensor_perf_model.py'),
    @('.\model\test_window_cache_perf_model.py'),
    @('.\model\test_throughput_sweep.py'),
    @('.\model\test_read_burst_profile_model.py'),
    @('.\model\test_read_rsp_pop_refill_model.py'),
    @('.\model\test_write_rsp_pop_refill_model.py'),
    @('.\model\test_read_ar_bypass_model.py'),
    @('.\model\test_mac_output_restart_model.py'),
    @('.\model\test_mac_tag_pop_push_model.py'),
    @('.\model\test_write_req_pop_refill_model.py')
)

Push-Location $caseRoot
try {
    foreach ($arguments in $commands) {
        & $Python @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Python regression failed: $($arguments -join ' ')"
        }
    }
} finally {
    Pop-Location
}

Write-Output 'C1_PYTHON_REGRESSION_PASS commands=21'
