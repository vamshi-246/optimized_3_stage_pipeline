Param(
    [string]$Hex = "tests/sample_program.hex",
    [int]$MaxCycles = 200,
    [string]$Trace = "sim/pipeline_trace.log",
    [string]$Vcd = "sim/out.vcd",
    [switch]$NoShow
)

$ErrorActionPreference = "Stop"

function Ensure-Tool($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$name' not found in PATH."
    }
}

Ensure-Tool iverilog
Ensure-Tool vvp
Ensure-Tool python

New-Item -ItemType Directory -Force -Path "sim" | Out-Null

$compileArgs = @(
    "-g2012",
    "-o", "sim/run.vvp",
    "src/core/rv32i_pkg.sv",
    "sim/universal_tb.sv",
    "sim/simple_memory.sv",
    "src/core/rv32i_cpu.sv",
    "src/units/alu.sv",
    "src/units/branch_unit.sv",
    "src/units/imm_gen.sv",
    "src/units/regfile.sv",
    "src/units/decoder.sv",
    "src/units/hazard_unit.sv",
    "src/units/forward_unit.sv",
    "src/units/issue_unit.sv",
    "src/units/reg_status_table.sv"
)


Write-Host "Compiling RTL with iverilog..."
iverilog @compileArgs

Write-Host "Running simulation..."
vvp "sim/run.vvp" "+HEX=$Hex" "+MAX_CYCLES=$MaxCycles" "+DUMPFILE=$Vcd"

if (-not (Test-Path $Trace)) {
    Write-Warning "Trace file '$Trace' not found after simulation; skipping analysis."
    exit 1
}

$analyzeArgs = @("--trace", $Trace, "--hex", $Hex)
if (-not $NoShow) { $analyzeArgs += "--show" }

Write-Host "Analyzing pipeline trace..."
python "tools/analyze_pipeline.py" @analyzeArgs

Write-Host "Done."
