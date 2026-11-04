`timescale 1ps/1ps

module ph1p_ddrphy_byte_wrapper #(
    parameter        BYTE_TYPE   = "DX" ,
    parameter [51:0] PAD_TYPE    = 52'hf_6666_5466_0000,
    parameter        MDL_MODE    = "FULL",
    parameter        AC_DRV      = "48",
    parameter        DX_DRV      = "48",
    parameter        DX_ODT      = "60"
) (
     
    input   [  3:0]  io_clk          ,
    input            usr_clk         ,

    input            ctl_rst_n       ,
    input            dqs_rst_n       ,
    input            ac_phy_rst_n    ,
    input            dx_phy_rst_n    ,
    input            dx_fifo_rst_n   ,

    input   [  7:0]  ctl_oe          ,
    input   [  7:0]  ctl_te          ,
    input   [  7:0]  ctl_pdr         ,

    input            dx_rfifo_en     ,

    input   [103:0]  ctl_wdata       ,
    output           ctl_rdata_vld   ,
    output  [103:0]  ctl_rdata       ,
    input   [  7:0]  ctl_rdqs_gate   ,

    input            apb_pclk        ,
    input            apb_prst_n      ,
    input            apb_psel        ,
    input            apb_penable     ,
    input            apb_pwrite      ,
    input   [  7:0]  apb_paddr       ,
    input   [ 31:0]  apb_pwdata      ,
    output           apb_pready      ,
    output  [ 31:0]  apb_prdata      ,
    output           apb_pslverr     ,

    input            dcp_psel        ,
    input   [  5:0]  dcp_paddr       ,
    input   [  8:0]  dcp_pdata       ,
    input            dcp_gate        ,

    input   [  6:0]  cal_clk_en      ,
    input            cal_mode        ,
    input   [  6:0]  cal_en          ,
    output  [  6:0]  cal_out         ,
    output  [  6:0]  cal_en_out      ,

    output  [ 15:0]  debug           ,
    input            lb_enb          ,
    input            wrlvl_mode      ,
    input            dqs_pupd_en     ,
    output  [  1:0]  dqs_gate_status ,
    output  [  1:0]  dqs_cnt         ,

    output  [ 12:0]  indd         ,
    inout   [ 12:0]  byte_io         
);

localparam BDL_WIDTH = 6;

wire                      phy_ctlclk_ac       ;
wire                      phy_ctlclk_dqs      ;
wire                      phy_ctlclk_wdq      ;
wire                      phy_phyclk          ;
wire                      phy_ddrclk_ac       ;
wire                      phy_ddrclk_dqs      ;
wire                      phy_ddrclk_wdq      ;

wire                      phy_ac_wr_rst_n     ;
wire                      phy_dx_wr_rst_n     ;
wire                      phy_ac_rd_rst_n     ;
wire                      phy_dx_rd_rst_n     ;

wire                      phy_rd_bdl_byp_dqsp ;
wire                      phy_rd_bdl_byp_dqsn ;
wire  [          10-1:0]  phy_rd_bdl_byp_dq   ;
wire                      phy_rd_bdl_byp_se   ; 

wire  [BDL_WIDTH   -1:0]  phy_rd_bdl_dly_dqsp ;
wire  [BDL_WIDTH   -1:0]  phy_rd_bdl_dly_dqsn ;
wire  [BDL_WIDTH*10-1:0]  phy_rd_bdl_dly_dq   ;
wire  [BDL_WIDTH   -1:0]  phy_rd_bdl_dly_se   ;

wire                      phy_wr_bdl_byp_dqsp ;
wire                      phy_wr_bdl_byp_dqsn ;
wire  [          10-1:0]  phy_wr_bdl_byp_dq   ;
wire                      phy_wr_bdl_byp_se   ;
wire  [BDL_WIDTH   -1:0]  phy_wr_bdl_dly_dqsp ;
wire  [BDL_WIDTH   -1:0]  phy_wr_bdl_dly_dqsn ;
wire  [BDL_WIDTH*10-1:0]  phy_wr_bdl_dly_dq   ;
wire  [BDL_WIDTH   -1:0]  phy_wr_bdl_dly_se   ;

wire  [          13-1:0]  phy_rd_bdl_byp  = {phy_rd_bdl_byp_se, phy_rd_bdl_byp_dq[9:6], phy_rd_bdl_byp_dqsn, phy_rd_bdl_byp_dqsp, phy_rd_bdl_byp_dq[5:0]};
wire  [          13-1:0]  phy_wr_bdl_byp  = {phy_wr_bdl_byp_se, phy_wr_bdl_byp_dq[9:6], phy_wr_bdl_byp_dqsn, phy_wr_bdl_byp_dqsp, phy_wr_bdl_byp_dq[5:0]};
wire  [BDL_WIDTH*13-1:0]  phy_rd_bdl_dly  = {phy_rd_bdl_dly_se, phy_rd_bdl_dly_dq[6*BDL_WIDTH +: 4*BDL_WIDTH], phy_rd_bdl_dly_dqsn, phy_rd_bdl_dly_dqsp, phy_rd_bdl_dly_dq[0 +: 6*BDL_WIDTH]};
wire  [BDL_WIDTH*13-1:0]  phy_wr_bdl_dly  = {phy_wr_bdl_dly_se, phy_wr_bdl_dly_dq[6*BDL_WIDTH +: 4*BDL_WIDTH], phy_wr_bdl_dly_dqsn, phy_wr_bdl_dly_dqsp, phy_wr_bdl_dly_dq[0 +: 6*BDL_WIDTH]};

wire           phy_pdr_dqsp                 ;
wire           phy_pdr_dqsn                 ;
wire           phy_pdr_dq                   ;
wire           phy_oe_dqsp                  ;
wire           phy_oe_dqsn                  ;
wire           phy_oe_dq                    ;
wire           phy_te_dqsp                  ;
wire           phy_te_dqsn                  ;
wire           phy_te_dq                    ;

wire  [ 23:0]  phy_oe_md                    ; 
wire  [ 23:0]  phy_te_md                    ;
wire  [ 23:0]  phy_pdr_md                   ;

wire  [13*2-1:0]  phy_oe_md_int  = {phy_oe_md [7*2 +: 5*2], phy_oe_md [6*2 +: 2], phy_oe_md [6*2 +: 2], phy_oe_md [0 +: 6*2]};
wire  [13*2-1:0]  phy_te_md_int  = {phy_te_md [7*2 +: 5*2], phy_te_md [6*2 +: 2], phy_te_md [6*2 +: 2], phy_te_md [0 +: 6*2]};
wire  [13*2-1:0]  phy_pdr_md_int = {phy_pdr_md[7*2 +: 5*2], phy_pdr_md[6*2 +: 2], phy_pdr_md[6*2 +: 2], phy_pdr_md[0 +: 6*2]};

wire  [13*8-1:0]  phy_wdata                    ;
wire              phy_rdqs_p                   ;
wire              phy_rdqs_n                   ;
wire  [13*8-1:0]  phy_rdata                    ;
wire              phy_rdqs_o                   ;
wire              phy_rdqs_gate                ;
wire              phy_rdqs_gate_ex             ;

wire  [13  -1:0]  phy_rdqs                     ;  

`ifdef PH1P_FPSOC
DR1P_PHY_DDRPHY_BYTE #(
`else
PH1P_PHY_DDRPHY_BYTE #(
`endif
    .BYTE_TYPE            ( BYTE_TYPE       ),   
    .DDR_CLK_SWI_SEL      ("IOCLK1"         ),   
    .CTL_CLK_SWI_SEL      ("IOCLK0"         ),   
    .DLY_TEST_EN          ("DISABLE"        ),   
    .DLY_CAL_MODE         ( MDL_MODE        ),   
    .WL_GATE_DIS_EN       ("ENABLE"         ),   
    .DQS_GATE_TYPE        ("DQS"            ),   
`ifdef PH1P_DDRPHY_SIM
    .DCC_EN               ("DISABLE"        ),   
`else
    .DCC_EN               ("ENABLE"         ),   
`endif
    .DCC_CLK_SEL          ("CLK_IO"         )    
) u_ddrphy_byte (

    .lclk                ( 4'b0                ),
    .ioclk               ( io_clk              ),
    .usr_clk             ( usr_clk             ),
    .ac_fifo_rst_n       ( 1'b0                ),
    .dx_fifo_rst_n       ( dx_fifo_rst_n       ),
    .ac_phy_rst_n        ( ac_phy_rst_n        ),
    .dx_phy_rst_n        ( dx_phy_rst_n        ),
    .dqs_rst_n           ( dqs_rst_n           ),
    .ctl_rst_n           ( ctl_rst_n           ),

    .ctl_oe              ( ctl_oe              ),
    .ctl_te              ( ctl_te              ),
    .ctl_pdr             ( ctl_pdr             ),

    .ac_rfifo_en         ( 1'b0                ),
    .ac_rfifo_mode       ( 1'b0                ),
    .dx_rfifo_en         ( dx_rfifo_en         ),
    .dx_rfifo_mode       ( 1'b0                ),  

    .ctl_wdata           ( ctl_wdata           ),
    .ctl_rdata_vld       ( ctl_rdata_vld       ),
    .ctl_rdata           ( ctl_rdata           ),
    .ctl_rdqs_gate       ( ctl_rdqs_gate       ),

    .apb_pclk            ( apb_pclk            ),
    .apb_prst_n          ( apb_prst_n          ),
    .apb_psel            ( apb_psel            ),
    .apb_penable         ( apb_penable         ),
    .apb_pwrite          ( apb_pwrite          ),
    .apb_paddr           ({2'b00, apb_paddr[7:0]}),
    .apb_pwdata          ( apb_pwdata          ),
    .apb_prdy            ( apb_pready          ),
    .apb_prdata          ( apb_prdata          ),
    .apb_pslverr         ( apb_pslverr         ),

    .dly_psel            ( dcp_psel            ),
    .dly_pdata           ( dcp_pdata           ),
    .dly_paddr           ( dcp_paddr           ),
    .dly_gate            ( dcp_gate            ),

    .cal_clk_en          ( cal_clk_en          ),
    .cal_mode            ( cal_mode            ),
    .cal_en              ( cal_en              ),
    .cal_out             ( cal_out             ),
    .cal_en_out          ( cal_en_out          ),

    .dcc_clrsr           ( 1'b0                ),
    .dcc_start           ( 1'b0                ),
    .dcc_done            (                     ),

    .dl_test_mode        ( 1'b0                ),
    .dl_osc_en           ( 1'b0                ),
    .dl_osc_wlsel        ( 2'b11               ),
    .dl_osc_wdqsel       ( 2'b11               ),
    .dl_osc_div          ( 4'hf                ),
    .dl_osc_out          (                     ),

    .o_debug             ( debug               ),

    .lb_mode             ( 1'b0                ),
    .lb_en               ( 8'b0                ),
    .lb_sel              ( 2'b0                ),
    .lb_ck_sel           ( 2'b0                ),

    .dqs_pupd_en         ( dqs_pupd_en         ),
    .wrlvl_mode          ( wrlvl_mode          ),
    .dqs_gate_status     ( dqs_gate_status     ),
    .dqsn_cnt            ( dqs_cnt             ),

    .phy_phyclk          ( phy_phyclk          ),
    .phy_ctlclk_ac       ( phy_ctlclk_ac       ),
    .phy_ddrclk_ac       ( phy_ddrclk_ac       ),
    .phy_ctlclk_wdq      ( phy_ctlclk_wdq      ),
    .phy_ctlclk_dqs      ( phy_ctlclk_dqs      ),
    .phy_ddrclk_dqs      ( phy_ddrclk_dqs      ),
    .phy_ddrclk_wdq      ( phy_ddrclk_wdq      ),

    .phy_ac_wr_rst_n     ( phy_ac_wr_rst_n     ),
    .phy_dx_wr_rst_n     ( phy_dx_wr_rst_n     ),
    .phy_ac_rd_rst_n     ( phy_ac_rd_rst_n     ),
    .phy_dx_rd_rst_n     ( phy_dx_rd_rst_n     ),

    .phy_pdr_md          ( phy_pdr_md          ),
    .phy_te_md           ( phy_te_md           ),
    .phy_oe_md           ( phy_oe_md           ),

    .phy_oe_dq           ( phy_oe_dq           ),
    .phy_oe_dqsp         ( phy_oe_dqsp         ),
    .phy_oe_dqsn         ( phy_oe_dqsn         ),
    .phy_pdr_dq          ( phy_pdr_dq          ),
    .phy_pdr_dqsp        ( phy_pdr_dqsp        ),
    .phy_pdr_dqsn        ( phy_pdr_dqsn        ),
    .phy_te_dq           ( phy_te_dq           ),
    .phy_te_dqsp         ( phy_te_dqsp         ),
    .phy_te_dqsn         ( phy_te_dqsn         ),

    .phy_wdata           ( phy_wdata           ),
    .phy_rdata           ( phy_rdata           ),

    .phy_wr_bdl_dly_dq   ( phy_wr_bdl_dly_dq   ),
    .phy_wr_bdl_dly_dqsp ( phy_wr_bdl_dly_dqsp ),
    .phy_wr_bdl_dly_dqsn ( phy_wr_bdl_dly_dqsn ),
    .phy_wr_bdl_dly_se   ( phy_wr_bdl_dly_se   ),
    .phy_rd_bdl_dly_dq   ( phy_rd_bdl_dly_dq   ),
    .phy_rd_bdl_dly_dqsp ( phy_rd_bdl_dly_dqsp ),
    .phy_rd_bdl_dly_dqsn ( phy_rd_bdl_dly_dqsn ),
    .phy_rd_bdl_dly_se   ( phy_rd_bdl_dly_se   ),

    .phy_wr_bdl_byp_dq   ( phy_wr_bdl_byp_dq   ),
    .phy_wr_bdl_byp_dqsp ( phy_wr_bdl_byp_dqsp ),
    .phy_wr_bdl_byp_dqsn ( phy_wr_bdl_byp_dqsn ),
    .phy_wr_bdl_byp_se   ( phy_wr_bdl_byp_se   ),
    .phy_rd_bdl_byp_dq   ( phy_rd_bdl_byp_dq   ),
    .phy_rd_bdl_byp_dqsp ( phy_rd_bdl_byp_dqsp ),
    .phy_rd_bdl_byp_dqsn ( phy_rd_bdl_byp_dqsn ),
    .phy_rd_bdl_byp_se   ( phy_rd_bdl_byp_se   ),

    .phy_rdqs_p          ( phy_rdqs[6]         ),
    .phy_rdqs_n          ( phy_rdqs[7]         ),
    .phy_rdqs_o          ( phy_rdqs_o          ),
    .phy_rdqs_gate       ( phy_rdqs_gate       ),

    .scan_clk            ( 1'b0                ),
    .scan_rst_n          ( 1'b1                ),
    .scan_mode           ( 1'b0                ),
    .scan_enable         ( 1'b0                ),
    .scancompress_mode   ( 1'b0                ),
    .scan_in             ( 3'b0                ),
    .scan_out            (                     ),

    .dly_ranksel         ( 1'b0                ),
    .dcc_up_en           ( 1'b0                ),
    .dfi_io_pd           ( 1'b0                ),
    .dfi_dcc_vt_update   ( 1'b0                ),
    .qs_gate             ( 1'b0                ),
    .apb_sync_path_en    ( 1'b0                ),
    .aa_code_invert      ( 1'b0                ),
    .aa_en               ( 1'b0                ),

    .ctl_clk_gate        ( 1'b1                ),
    .ctl_rd_clk_gate     ( 1'b1                ),
    .ctl_phy_clk_gate    ( 1'b1                )
);

genvar n;

generate
for (n = 0; n <= 12; n = n+1) begin : ddrphy_pad
    if (PAD_TYPE[4*n +: 4] != 4'hf) begin : pad_used
`ifdef PH1P100
        PH1P_PHY_DDRPHY_PAD    #(
`elsif PH1P35_HRIO_PAD
        PH1P_PHY_DDRPHY_PAD    #(
`elsif PH1P35_DDRIO_PAD
        PH1P_PHY_DDRPHY_PAD_V2 #(
`elsif PH1P50_HRIO_PAD
        PH1P_PHY_DDRPHY_PAD    #(
`elsif PH1P50_DDRIO_PAD
        PH1P_PHY_DDRPHY_PAD_V3 #(
`elsif PH1P_FPSOC_HRIO_PAD
        DR1P_PHY_DDRPHY_PAD #(
`elsif PH1P_FPSOC_HPIO_PAD
        DR1P_PHY_DDRPHY_PAD_V2 #(
`endif
            .MODE              ((PAD_TYPE[4*n +: 4] == 4'b0000) ? "OUT"     : "BI" ),  
            .DDR_SIGNAL_TYPE   ((PAD_TYPE[4*n +: 4] == 4'b0000) ? "AC"      :
                                (PAD_TYPE[4*n +: 4] == 4'b0100) ? "DQSP"    :
                                (PAD_TYPE[4*n +: 4] == 4'b0101) ? "DQSN"    :
                                (PAD_TYPE[4*n +: 4] == 4'b0110) ? "DQ"      : "AC" ),
            .OCLK_SEL          ((PAD_TYPE[4*n +: 4] == 4'b0000) ? "CLK_IO"  :  
                                (PAD_TYPE[4*n +: 4] == 4'b0100) ? "CLK_WL"  :
                                (PAD_TYPE[4*n +: 4] == 4'b0101) ? "CLK_WL"  :
                                (PAD_TYPE[4*n +: 4] == 4'b0110) ? "CLK_WDQ" : "CLK_IO" ),
            .DATA_OUT_SYNC     ( "DISABLE"           ),
            .DATA_WIDTH        ( "X8"                ),
            .ODT_SRC_SEL       ( "SRAM"              ),  
            .DRV               ((PAD_TYPE[4*n +: 4] == 4'b0000) ? AC_DRV : DX_DRV ),
            .ODT               ( DX_ODT              ),
            .DDR_RST_TYPE      ( "ASYNC"             ),
            .DISABLE_GSR       ( "ENABLE"            )
        ) u_byte_io (
    
            .pad              ( byte_io [n]    ),

            .ctl_phy_clk      ( phy_phyclk     ),
            .ctl_clk_ac       ( phy_ctlclk_ac  ),
            .ctl_clk_dqs      ( phy_ctlclk_dqs ),
            .ctl_clk_wdq      ( phy_ctlclk_wdq ),
            .ddr_clk_ac       ( phy_ddrclk_ac  ),
            .ddr_clk_dqs      ( phy_ddrclk_dqs ),
            .ddr_clk_wdq      ( phy_ddrclk_wdq ),
    
            .ac_wr_rst_n      ( phy_ac_wr_rst_n),
            .dx_wr_rst_n      ( phy_dx_wr_rst_n),
            .ac_rd_rst_n      ( phy_ac_rd_rst_n),
            .dx_rd_rst_n      ( phy_dx_rd_rst_n),

            .rdqs             ( phy_rdqs_o     ),
            .rdqs_gate        ( phy_rdqs_gate  ),

            .doq              ( phy_wdata      [n*8 +: 8] ),
            .diq              ( phy_rdata      [n*8 +: 8] ),

            .ts_md            ( phy_oe_md_int  [n*2 +: 2] ),
            .te_md            ( phy_te_md_int  [n*2 +: 2] ),
            .pdr_md           ( phy_pdr_md_int [n*2 +: 2] ),
            .ts_dq            ( phy_oe_dq      ),
            .ts_dqs           ( phy_oe_dqsp    ),
            .ts_dqsn          ( phy_oe_dqsn    ),
            .pdr_dq           ( phy_pdr_dq     ),
            .pdr_dqs          ( phy_pdr_dqsp   ),
            .pdr_dqsn         ( phy_pdr_dqsn   ),
            .te_dq            ( phy_te_dq      ),
            .te_dqs           ( phy_te_dqsp    ),
            .te_dqsn          ( phy_te_dqsn    ),

            .in_bdl_byp       ( phy_rd_bdl_byp[n]                        ),
            .in_bdl_dly       ( phy_rd_bdl_dly[n*BDL_WIDTH +: BDL_WIDTH] ),
            .out_bdl_byp      ( phy_wr_bdl_byp[n]                        ),
            .out_bdl_dly      ( phy_wr_bdl_dly[n*BDL_WIDTH +: BDL_WIDTH] ),

            .indd             ( indd    [n]    ),  
            .indqs            ( phy_rdqs[n]    ),  
            .lb_enb           ( lb_enb         )
        );
    end else begin : pad_unused
        assign indd[n] = 1'b0;
    end  
end
endgenerate

endmodule
