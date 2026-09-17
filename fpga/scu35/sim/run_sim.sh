#!/usr/bin/env bash
# run_sim.sh - build and run the SCU35 SoC simulations with Verilator
#
#   ./run_sim.sh unit      UART + interconnect unit test (no core)
#   ./run_sim.sh soc       whole SoC running sw/apps/uart_demo
#   ./run_sim.sh           both
#
# Needs Verilator 5.x (--timing). Run from anywhere; paths are resolved
# from this script's location.
set -euo pipefail

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_RTL="$SIM_DIR/../rtl"
CORE_RTL="$SIM_DIR/../../../rtl"
BHV="$SIM_DIR/../../../bhv"
COE="$SIM_DIR/../mem_init_file/uart_demo.coe"
OUT="$SIM_DIR/build"
mkdir -p "$OUT"

WARN="-Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-MULTIDRIVEN -Wno-BLKANDNBLK -Wno-UNOPTFLAT"

periph_srcs=(
    "$FPGA_RTL/sync_fifo.sv"
    "$FPGA_RTL/uart_tx.sv"
    "$FPGA_RTL/uart_rx.sv"
    "$FPGA_RTL/uart_peripheral.sv"
    "$FPGA_RTL/obi_data_interconnect.sv"
)

run_unit() {
    echo "=== unit: tb_uart_periph ==="
    set -- unit
    verilator --binary --timing -j 0 $WARN --top-module tb_uart_periph \
        -Mdir "$OUT/unit" "${periph_srcs[@]}" "$SIM_DIR/tb_uart_periph.sv" > "$OUT/verilator_$1.log" 2>&1 || { tail -40 "$OUT/verilator_$1.log"; exit 1; }
    "$OUT/unit/Vtb_uart_periph"
}

run_soc() {
    echo "=== soc: tb_uart_soc ==="
    # COE -> plain hex for $readmemh
    sed -n '/memory_initialization_vector/,$p' "$COE" | tail -n +2 \
        | tr -d ',; \r' | grep -v '^$' > "$OUT/uart_demo.hex"

    core_srcs=(
        "$CORE_RTL/include/cv32e40x_pkg.sv"
        $(ls "$CORE_RTL"/cv32e40x_*.sv)
        "$BHV/cv32e40x_sim_clock_gate.sv"
    )
    # FPGA RTL minus the BUFGCE clock gate (replaced by the sim clock gate)
    fpga_srcs=(
        "${periph_srcs[@]}"
        "$FPGA_RTL/led_peripheral.sv"
        "$FPGA_RTL/memory_controller.sv"
        "$FPGA_RTL/reset_synchronizer.sv"
        "$FPGA_RTL/cv32e40x_wrapper.sv"
    )
    set -- soc
    verilator --binary --timing -j 0 $WARN --top-module tb_uart_soc \
        -I"$CORE_RTL/include" -Mdir "$OUT/soc" \
        "${core_srcs[@]}" "$SIM_DIR/xilinx_sim_models.sv" "${fpga_srcs[@]}" \
        "$SIM_DIR/tb_uart_soc.sv" > "$OUT/verilator_$1.log" 2>&1 || { tail -40 "$OUT/verilator_$1.log"; exit 1; }
    "$OUT/soc/Vtb_uart_soc" +MEM_HEX="$OUT/uart_demo.hex"
}

case "${1:-all}" in
    unit) run_unit ;;
    soc)  run_soc ;;
    all)  run_unit; run_soc ;;
    *)    echo "usage: $0 [unit|soc|all]"; exit 2 ;;
esac
