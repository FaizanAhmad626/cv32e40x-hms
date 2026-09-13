`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 06/12/2026 04:08:12 PM
// Design Name: 
// Module Name: cv32e40x_wrapper
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module cv32e40x_wrapper import cv32e40x_pkg::*;
#(
// ---------------------------------------------------------------------------
// Address map. These values are duplicated in software and in the BRAM IP
// configuration; all four places must agree:
//   link.ld        ORIGIN(MEM) = BOOT_ADDR, LENGTH(MEM) = MEM_DEPTH * 4
//   crt0.S         trap_handler placed at MT_VEC_ADDR, .align 7
//   main.c         LED_REG address = LED_BASE
//   blk_mem_gen_0  Write_Depth_A = MEM_DEPTH
//
// RISC-V does not mandate any of these addresses. The privileged spec leaves
// the reset vector, memory base, and MMIO layout implementation-defined; only
// the mtvec CSR layout itself is standardised. The values below follow common
// RISC-V platform convention so the map is legible to anyone who has seen
// another RISC-V system.
// ---------------------------------------------------------------------------
parameter               BOOT_ADDR           = 32'h8000_0000,    // Reset PC. Conventional RISC-V main-memory base (QEMU virt, SiFive): low 2 GB is left for boot ROM and peripherals, RAM starts at the 2 GB mark. Must be word aligned, must equal MEM_BASE and ORIGIN(MEM), and _start must be the first thing the linker places there.
parameter               DM_REGION_START     = 32'hF000_0000,    // Debug module base. Unused while DEBUG = 0. Chosen well clear of MEM and the peripheral region so enabling debug later needs no renumbering. Will become a third interconnect slave at that point; currently decodes as unmapped and returns a bus error.
parameter               DM_REGION_END       = 32'hF000_3FFF,    // 16 KB debug region, enough for the riscv-dbg debug ROM and its program buffer.
parameter               DM_EXCEPTION_ADDR   = 32'hF000_0808,    // Debug-mode exception entry = DM_REGION_START + 0x808, the riscv-dbg ROM layout. The manual requires this to fall inside [DM_REGION_START, DM_REGION_END].
parameter               DM_HALT_ADDR        = 32'hF000_0800,    // Debug-mode halt entry = DM_REGION_START + 0x800, same ROM layout and same containment requirement.
parameter               M_HART_ID           = 32'h0000_0000,    // Single-hart system, so hart 0. Readable via the mhartid CSR.
parameter               MT_VEC_ADDR         = 32'h8000_0100,    // Trap-handler base, used until crt0.S writes mtvec. Three constraints: must be 128-byte aligned because CV32E40X hardwires mtvec[6:2] to 0 (a misaligned write silently rounds down); must be in mapped memory or a trap fetches from unmapped space and loops forever; must not collide with _start at BOOT_ADDR. 0x80 would leave _start only 128 bytes, so 0x100 gives it 256 with margin.
parameter int unsigned  CLIC_ID_WIDTH       = 5,                // Unused: CLIC = 0, so the core is in CLINT mode.
parameter               LED_BASE            = 32'h1000_0000,    // MMIO peripheral region. Differs from MEM_BASE in the top hex digit, so the decode is a comparison on addr[31:28] rather than a wide comparator. Peripherals added later (timer, UART, audio FIFO, accelerator) get 64 KB slots from 0x1001_0000 upward.
parameter               MEM_BASE            = 32'h8000_0000,    // Base of the unified instruction+data memory, decoded by obi_data_interconnect. Same value as BOOT_ADDR because boot is at the first word of memory, but kept as a separate parameter: if boot ever moves to an offset within memory, the region base must not follow it.
parameter int unsigned  MEM_DEPTH           = 16384             // 16384 x 32-bit words = 64 KB, holding .text, .rodata, .data, .bss and the stack. Sets the decode width: ADDR_WIDTH = 14, so the region tag is addr[31:16].
)
(
    input   logic           clk_p_i,    // Clock signal
    input   logic           clk_n_i,    // Clock signal
    input   logic           rst_ni,     // Active-low asynchronous reset 
    
    output  logic   [7:0]   led_o       // LED signals
    );  


// ---------------------------------------------------------------------------    
// ---------------------------------------------------------------------------
//  Signal declarations
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
//  Clock / reset
// ---------------------------------------------------------------------------
/*
Design for test (DfT) related signal.
Can be used during scan testing operation to force instantiated clock gate(s) to be enabled.
This signal should be 0 during normal / functional operation.
*/
logic   scan_cg_en_s;   // Scan clock gate enable
logic   clk_50M_s;      // Downconverted clock signal to initially meet timing requirements    
logic   clk_200M_s;     // Single-ended clock signal    
logic   rst_ns;         // Synchronized reset signal    

// ---------------------------------------------------------------------------
//  Static configuration
// ---------------------------------------------------------------------------
/*
First program counter after reset = boot_addr.
Must be word aligned.
Do not change after enabling core via fetch_enable_i.
*/
logic [31:0] boot_addr_s;           // Boot address
/*
Address to jump to when an exception occurs when executing code during Debug Mode.
Must be word aligned.
Do not change after enabling core via fetch_enable_i.
*/
logic [31:0] dm_exception_addr_s;   // Address for debugger exception entry
/*
Address to jump to when entering Debug Mode.
Must be word aligned.
Do not change after enabling core via fetch_enable_i.
*/
logic [31:0] dm_halt_addr_s;        // Address for debugger entry
/*
usually static, can be read from Hardware Thread ID (mhartid) CSR
*/
logic [31:0] mhartid_s;             // Hart ID
/*
Must be static.
Readable as part of Machine Implementation ID (mimpid) CSR.
*/
logic [ 3:0] mimpid_patch_s;        // Implementation ID patch
/*
Initial value for the address part of Machine Trap-Vector Base Address (mtvec) - CLIC == 0.
Must be 128-byte aligned (i.e. mtvec_addr_i[6:0] = 0).
Do not change after enabling core via fetch_enable_i.
*/
logic [31:0] mtvec_addr_s;          // mtvec address

// ---------------------------------------------------------------------------
// Instruction OBI (core = master)
// ---------------------------------------------------------------------------
logic        instr_req_s;       // Request valid, will stay high until instr_gnt_i is high for one cycle
/*
The other side accepted the request.
instr_addr_o, instr_memtype_o and instr_prot_o may change in the next cycle.
*/
logic        instr_gnt_s;
/*
instr_rdata_i and instr_err_i are valid when instr_rvalid_i is high.
This signal will be high for exactly one cycle per request.
*/
logic        instr_rvalid_s;
logic [31:0] instr_addr_s;      // Address, word aligned
logic [ 1:0] instr_memtype_s;   // Memory Type attributes, (cacheable, bufferable)
logic [ 2:0] instr_prot_s;      // Protection attributes
logic        instr_dbg_s;       // Debug mode access
logic [31:0] instr_rdata_s;     // Data read from memory
logic        instr_err_s;       // An instruction interface error occurred

// ---------------------------------------------------------------------------
// Data OBI (core = master)
// --------------------------------------------------------------------------- 
logic        data_req_s;        // Request valid, will stay high until data_gnt_i is high for one cycle
/*
The other side accepted the request.
data_addr_o, data_atop_o, data_be_o, data_memtype_o[2:0], data_prot_o, data_wdata_o, data_we_o may change in the next cycle.
*/
logic        data_gnt_s;
/*
data_rvalid_i will be high for exactly one cycle to signal the end of the response phase of for both read and write transactions.
For a read transaction data_rdata_i holds valid data when data_rvalid_i is high.
*/
logic        data_rvalid_s;
logic [31:0] data_addr_s;       // Address, sent together with data_req_o
/*
Is set for the bytes to write/read, sent together with data_req_o.
*/
logic [ 3:0] data_be_s;         // Byte Enable
/*
high for writes, low for reads.
Sent together with data_req_o.
*/
logic        data_we_s;         // Write Enable
logic [31:0] data_wdata_s;      // Data to be written to memory, sent together with data_req_o
logic [ 1:0] data_memtype_s;    // Memory Type attributes (cacheable, bufferable), sent together with data_req_o
logic [ 2:0] data_prot_s;       // Protection attributes, sent together with data_req_o
logic        data_dbg_s;        // Debug mode access, sent together with data_req_o
logic [ 5:0] data_atop_s;       // Atomic attributes, sent together with data_req_o
/*
Only valid when data_rvalid_i is high.
*/
logic [31:0] data_rdata_s;      // Data read from memory
/*
Only valid when data_rvalid_i is high.
*/
logic        data_err_s;        // A data interface error occurred
/*
Only valid when data_rvalid_i is high.
*/
logic        data_exokay_s;     // Exclusive transaction status

// ---------------------------------------------------------------------------
// Counters / time
// --------------------------------------------------------------------------- 
logic [63:0] mcycle_s;  // Cycle Counter Output
logic [63:0] time_s;    // Time input

// ---------------------------------------------------------------------------
// Interrupts -- CLINT mode (CLIC == 0)
// ---------------------------------------------------------------------------  
logic [31:0] irq_s;     // Interrupts
logic        wu_wfe_s;  // Wake-up for wfe (positive level sensitive)

// ---------------------------------------------------------------------------
// Interrupts -- CLIC mode (CLIC == 1)
// --------------------------------------------------------------------------- 
logic        clic_irq_s;                   // Is there any pending-and-enabled interrupt
logic [CLIC_ID_WIDTH-1:0] clic_irq_id_s;   // Index of the most urgent pending-and-enabled interrupt
logic [ 7:0] clic_irq_level_s;             // Interrupt level of the most urgent pending-and-enabled interrupt 
/*
Only machine-mode interrupts are supported.
*/
logic [ 1:0] clic_irq_priv_s;              // Associated privilege mode of the most urgent pending-and-enabled interrupt
logic        clic_irq_shv_s;               // Selective hardware vectoring enabled for the most urgent pending-and-enabled interrupt

// ---------------------------------------------------------------------------
// fence.i handshake
// ---------------------------------------------------------------------------  
/*
The fencei_flush_req_o signal will go high upon executing a fence.i instruction once possible earlier store instructions have fully completed (including emptying of the write buffer)
The fencei_flush_req_o signal will go low again the cycle after sampling both fencei_flush_req_o and fencei_flush_ack_i high
*/
logic        fencei_flush_req_s;
/*
If the fence.i external handshake is not used by the environment of CV32E40X, then it is recommended to tie the fencei_flush_ack_i to 1 in order to avoid stalling fence.i instructions indefinitely
*/
logic        fencei_flush_ack_s;

// ---------------------------------------------------------------------------
// Debug
// ---------------------------------------------------------------------------   
logic        debug_req_s;       // Request to enter Debug Mode
logic        debug_havereset_s; // Debug status: Core has been reset
logic        debug_running_s;   // Debug status: Core is running
logic        debug_halted_s;    // Debug status: Core is halted
logic        debug_pc_valid_s;  // Valid signal for debug_pc_o
logic [31:0] debug_pc_s;        // PC of last retired instruction

// ---------------------------------------------------------------------------
// CPU control
// ---------------------------------------------------------------------------    
/*
The first instruction fetch after reset de-assertion will not happen as long as this signal is 0.
fetch_enable_i needs to be set to 1 for at least one cycle while not in reset to enable fetching.
Once fetching has been enabled the value fetch_enable_i is ignored.
*/
logic        fetch_enable_s;    // Enable the instruction fetch of CV32E40X
logic        core_sleep_s;      // Core is sleeping

// ---------------------------------------------------------------------------
// Interconnect to memory slave
// ---------------------------------------------------------------------------
logic        mem_req_s;
logic        mem_gnt_s;
logic        mem_rvalid_s;
logic [31:0] mem_addr_s;
logic [ 3:0] mem_be_s;
logic        mem_we_s;
logic [31:0] mem_wdata_s;
logic [ 1:0] mem_memtype_s;
logic [ 2:0] mem_prot_s;
logic        mem_dbg_s;
logic [ 5:0] mem_atop_s;
logic [31:0] mem_rdata_s;
logic        mem_err_s;
logic        mem_exokay_s;

// ---------------------------------------------------------------------------
// Interconnect to LED slave
// ---------------------------------------------------------------------------
logic        led_req_s;
logic        led_gnt_s;
logic        led_rvalid_s;
logic [31:0] led_addr_s;
logic [ 3:0] led_be_s;
logic        led_we_s;
logic [31:0] led_wdata_s;
logic [31:0] led_rdata_s;
logic        led_err_s;
logic [ 7:0] led_pins_s;

// ---------------------------------------------------------------------------
// LED Signals
// ---------------------------------------------------------------------------
logic [25:0] heartbeat_q;

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
//  Signal assignments
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

assign scan_cg_en_s         =  1'b0;                    // tie to 0 for running on hardware and 1 for running simulation
assign boot_addr_s          = BOOT_ADDR;
assign dm_exception_addr_s  = DM_EXCEPTION_ADDR;
assign dm_halt_addr_s       = DM_HALT_ADDR;
assign mhartid_s            = M_HART_ID;
assign mimpid_patch_s       =  4'h0;
assign mtvec_addr_s         = MT_VEC_ADDR;
assign time_s               = 64'h0000_0000_0000_0000;
assign irq_s                = 32'h0000_0000;            // disable interrupts
assign wu_wfe_s             =  1'b0;
assign clic_irq_s           =  1'b0;
assign clic_irq_id_s        =   'd0;
assign clic_irq_level_s     =  8'h00;
assign clic_irq_priv_s      =  2'h0;
assign clic_irq_shv_s       =  1'b0;
assign debug_req_s          =  1'b0;                    // disable debug mode
assign fencei_flush_ack_s   =  fencei_flush_req_s;      // to avoid stalling fence.i instructions indefinitely
assign fetch_enable_s       =  1'b1;                    // enable instruction fetch
assign led_o = { heartbeat_q[25], led_pins_s[6:0] };    // LED signals

always_ff @(posedge clk_50M_s or negedge rst_ns) begin
  if (!rst_ns) heartbeat_q <= '0;
  else         heartbeat_q <= heartbeat_q + 1'b1;
end

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
//  Instantiations
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------

IBUFDS #(
    .DIFF_TERM ("TRUE"),
    .IOSTANDARD("LVDS")
  ) u_ibufds_sysclk (
    .I  (clk_p_i),
    .IB (clk_n_i),
    .O  (clk_100M_s)
  );

clk_wiz_0 clock_downconverter
   (
    // Clock out ports
    .clk_out1   (   clk_50M_s   ),  // output clk_out1
    // Status and control signals
    .resetn     (   rst_ni      ),  // input resetn
   // Clock in ports
    .clk_in1    (   clk_100M_s  )   // input clk_in1
);

reset_synchronizer reset_synchronizer
(
    .clk_i  (   clk_50M_s   ),
    .rst_ni (   rst_ni      ),
    .rst_no (   rst_ns      )
);

cv32e40x_if_xif ext_if ();
    
cv32e40x_core
#(
  .LIB                ( 0              ),
  .RV32               ( RV32I          ),  // RV32I | RV32E
  .A_EXT              ( A_NONE         ),  // A_NONE | A (LR/SC + AMOs)
  .B_EXT              ( B_NONE         ),  // B_NONE | ZBA_ZBB_ZBS | ZBA_ZBB_ZBC_ZBS
  .M_EXT              ( M              ),  // M | ZMMUL
  .DEBUG              ( 1'b0           ),  // 1 = include debug module support
  .DM_REGION_START    ( DM_REGION_START),
  .DM_REGION_END      ( DM_REGION_END  ),
  .DBG_NUM_TRIGGERS   ( 0              ),  // 0..4 hardware breakpoints
  .PMA_NUM_REGIONS    ( 0              ),  // 0 = whole space is main memory
  .PMA_CFG            ( '{default: PMA_R_DEFAULT} ),
  .CLIC               ( 1'b0           ),  // 0 = CLINT; 1 = CLIC
  .CLIC_ID_WIDTH      ( CLIC_ID_WIDTH  ),
  .X_EXT              ( 1'b0           ),  // 1 = expose XIF ports
  .X_NUM_RS           ( 2              ),
  .X_ID_WIDTH         ( 4              ),
  .X_MEM_WIDTH        ( 32             ),
  .X_RFR_WIDTH        ( 32             ),
  .X_RFW_WIDTH        ( 32             ),
  .X_MISA             ( 32'h0000_0000  ),
  .X_ECS_XS           ( 2'b00          ),
  .NUM_MHPMCOUNTERS   ( 1              )   // 0..29
) 
RISCV_Core
(
  .clk_i              ( clk_50M_s          ),
  .rst_ni             ( rst_ns             ),
  .scan_cg_en_i       ( scan_cg_en_s       ),
 
  .boot_addr_i        ( boot_addr_s        ),
  .dm_exception_addr_i( dm_exception_addr_s),
  .dm_halt_addr_i     ( dm_halt_addr_s     ),
  .mhartid_i          ( mhartid_s          ),
  .mimpid_patch_i     ( mimpid_patch_s     ),
  .mtvec_addr_i       ( mtvec_addr_s       ),
 
  .instr_req_o        ( instr_req_s        ),
  .instr_gnt_i        ( instr_gnt_s        ),
  .instr_rvalid_i     ( instr_rvalid_s     ),
  .instr_addr_o       ( instr_addr_s       ),
  .instr_memtype_o    ( instr_memtype_s    ),
  .instr_prot_o       ( instr_prot_s       ),
  .instr_dbg_o        ( instr_dbg_s        ),
  .instr_rdata_i      ( instr_rdata_s      ),
  .instr_err_i        ( instr_err_s        ),
 
  .data_req_o         ( data_req_s         ),
  .data_gnt_i         ( data_gnt_s         ),
  .data_rvalid_i      ( data_rvalid_s      ),
  .data_addr_o        ( data_addr_s        ),
  .data_be_o          ( data_be_s          ),
  .data_we_o          ( data_we_s          ),
  .data_wdata_o       ( data_wdata_s       ),
  .data_memtype_o     ( data_memtype_s     ),
  .data_prot_o        ( data_prot_s        ),
  .data_dbg_o         ( data_dbg_s         ),
  .data_atop_o        ( data_atop_s        ),
  .data_rdata_i       ( data_rdata_s       ),
  .data_err_i         ( data_err_s         ),
  .data_exokay_i      ( data_exokay_s      ),
 
  .mcycle_o           ( mcycle_s           ),
  .time_i             ( time_s             ),
 
  .xif_compressed_if  ( ext_if             ),
  .xif_issue_if       ( ext_if             ),
  .xif_commit_if      ( ext_if             ),
  .xif_mem_if         ( ext_if             ),
  .xif_mem_result_if  ( ext_if             ),
  .xif_result_if      ( ext_if             ),
 
  .irq_i              ( irq_s              ),
  .wu_wfe_i           ( wu_wfe_s           ),
 
  .clic_irq_i         ( clic_irq_s         ),
  .clic_irq_id_i      ( clic_irq_id_s      ),
  .clic_irq_level_i   ( clic_irq_level_s   ),
  .clic_irq_priv_i    ( clic_irq_priv_s    ),
  .clic_irq_shv_i     ( clic_irq_shv_s     ),
 
  .fencei_flush_req_o ( fencei_flush_req_s ),
  .fencei_flush_ack_i ( fencei_flush_ack_s ),
 
  .debug_req_i        ( debug_req_s        ),
  .debug_havereset_o  ( debug_havereset_s  ),
  .debug_running_o    ( debug_running_s    ),
  .debug_halted_o     ( debug_halted_s     ),
  .debug_pc_valid_o   ( debug_pc_valid_s   ),
  .debug_pc_o         ( debug_pc_s         ),
 
  .fetch_enable_i     ( fetch_enable_s     ),
  .core_sleep_o       ( core_sleep_s       )
);

memory_controller
#(
    .MEM_DEPTH  (   MEM_DEPTH   )   // must match blk_mem_gen_0 depth
)
unified_memory_controller
(
    .clk_i              (   clk_50M_s       ),
    .rst_ni             (   rst_ns          ),

    .instr_req_i        (   instr_req_s     ),
    .instr_gnt_o        (   instr_gnt_s     ),
    .instr_rvalid_o     (   instr_rvalid_s  ),
    .instr_addr_i       (   instr_addr_s    ),
    .instr_memtype_i    (   instr_memtype_s ),
    .instr_prot_i       (   instr_prot_s    ),
    .instr_dbg_i        (   instr_dbg_s     ),
    .instr_rdata_o      (   instr_rdata_s   ),
    .instr_err_o        (   instr_err_s     ),

    .data_req_i         (   mem_req_s       ),
    .data_gnt_o         (   mem_gnt_s       ),
    .data_rvalid_o      (   mem_rvalid_s    ),
    .data_addr_i        (   mem_addr_s      ),
    .data_be_i          (   mem_be_s        ),
    .data_we_i          (   mem_we_s        ),
    .data_wdata_i       (   mem_wdata_s     ),
    .data_memtype_i     (   mem_memtype_s   ),
    .data_prot_i        (   mem_prot_s      ),
    .data_dbg_i         (   mem_dbg_s       ),
    .data_atop_i        (   mem_atop_s      ),
    .data_rdata_o       (   mem_rdata_s     ),
    .data_err_o         (   mem_err_s       ),
    .data_exokay_o      (   mem_exokay_s    )
);

obi_data_interconnect
#(
    .MEM_DEPTH  (   MEM_DEPTH       ),
    .MEM_BASE   (   MEM_BASE        ),
    .LED_BASE   (   LED_BASE        )
)
obi_data_interconnect
(
    .clk_i          (   clk_50M_s       ),
    .rst_ni         (   rst_ns          ),

    // upstream, from the core
    .data_req_i     (   data_req_s      ),
    .data_gnt_o     (   data_gnt_s      ),
    .data_rvalid_o  (   data_rvalid_s   ),
    .data_addr_i    (   data_addr_s     ),
    .data_be_i      (   data_be_s       ),
    .data_we_i      (   data_we_s       ),
    .data_wdata_i   (   data_wdata_s    ),
    .data_memtype_i (   data_memtype_s  ),
    .data_prot_i    (   data_prot_s     ),
    .data_dbg_i     (   data_dbg_s      ),
    .data_atop_i    (   data_atop_s     ),
    .data_rdata_o   (   data_rdata_s    ),
    .data_err_o     (   data_err_s      ),
    .data_exokay_o  (   data_exokay_s   ),

    // downstream, memory
    .mem_req_o      (   mem_req_s       ),
    .mem_gnt_i      (   mem_gnt_s       ),
    .mem_rvalid_i   (   mem_rvalid_s    ),
    .mem_addr_o     (   mem_addr_s      ),
    .mem_be_o       (   mem_be_s        ),
    .mem_we_o       (   mem_we_s        ),
    .mem_wdata_o    (   mem_wdata_s     ),
    .mem_memtype_o  (   mem_memtype_s   ),
    .mem_prot_o     (   mem_prot_s      ),
    .mem_dbg_o      (   mem_dbg_s       ),
    .mem_atop_o     (   mem_atop_s      ),
    .mem_rdata_i    (   mem_rdata_s     ),
    .mem_err_i      (   mem_err_s       ),
    .mem_exokay_i   (   mem_exokay_s    ),

    // downstream, LED
    .led_req_o      (   led_req_s       ),
    .led_gnt_i      (   led_gnt_s       ),
    .led_rvalid_i   (   led_rvalid_s    ),
    .led_addr_o     (   led_addr_s      ),
    .led_be_o       (   led_be_s        ),
    .led_we_o       (   led_we_s        ),
    .led_wdata_o    (   led_wdata_s     ),
    .led_rdata_i    (   led_rdata_s     ),
    .led_err_i      (   led_err_s       )
);

led_peripheral
#(
    .NUM_LEDS   (   7   )
)
led_peripheral
(
    .clk_i      (   clk_50M_s       ),
    .rst_ni     (   rst_ns          ),
    .req_i      (   led_req_s       ),
    .gnt_o      (   led_gnt_s       ),
    .rvalid_o   (   led_rvalid_s    ),
    .addr_i     (   led_addr_s      ),
    .be_i       (   led_be_s        ),
    .we_i       (   led_we_s        ),
    .wdata_i    (   led_wdata_s     ),
    .rdata_o    (   led_rdata_s     ),
    .err_o      (   led_err_s       ),
    .led_o      (   led_pins_s      )
);

endmodule