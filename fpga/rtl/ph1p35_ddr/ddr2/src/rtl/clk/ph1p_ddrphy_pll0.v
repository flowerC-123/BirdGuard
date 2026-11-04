`timescale 1 ns / 100 fs

module ph1p_ddrphy_pll0 #(
    parameter  REFCLK_FREQ = "100",
    parameter  REFCLK_DIV  = 3 ,
    parameter  FBKCLK_DIV  = 48,
    parameter  FRAC        = "DISABLE",
    parameter  FRAC_SDM    = 0 ,
    parameter  CLK2_DIV    = 4 ,
    parameter  CLK3_DIV    = 32
)(
    input   refclk  ,
    input   reset   ,
    output  clk0_out,
    output  clk1_out,
    output  clk2_out,
    output  clk3_out,
    output  lock
);

localparam  CLK0_DIV  = CLK2_DIV*4;
localparam  CLK1_DIV  = CLK2_DIV*4;

localparam  FAST_LOOP = "DISABLE";
localparam  LPF_RES   = 3;  
localparam  ICP_CUR   = 0; 
localparam  LPF_CAP   = ((FBKCLK_DIV >=   1) && (FBKCLK_DIV <   60)) ?  0 :
                        ((FBKCLK_DIV >=  60) && (FBKCLK_DIV <   80)) ?  6 :
                        ((FBKCLK_DIV >=  80) && (FBKCLK_DIV <  128)) ? 16 :
                        ((FBKCLK_DIV >= 128) && (FBKCLK_DIV <= 160)) ? 28 : 0;

wire  [6:0] clkc   ;
wire  [6:0] clkc_en;
wire        fbclk  ;

assign clkc_en  = 7'b000_1111;
assign clk0_out = clkc[0];
assign clk1_out = clkc[1];
assign clk2_out = clkc[2];
assign clk3_out = clkc[3];

assign fbclk = 1'b0;

`ifdef PH1P100
PH1P_PHY_PLL #(
`elsif PH1P35
PH1P_PHY_PLL_V2 #(
`elsif PH1P50
PH1P_PHY_PLL_V2 #(
`elsif PH1P_FPSOC
DR1P_PHY_PLL #(
`endif
 
    .FIN                          ( REFCLK_FREQ  ), 

    .PLL_FEED_TYPE                ( "INTERNAL"   ),  
    .FEEDBK_MODE                  ( "NOCOMP"     ),  
    .FBKCLK                       ( "VCO_PHASE0" ),
    .FBKCLK_INT                   ( "VCO_PHASE0" ),

    .REFCLK_DIV                   ( REFCLK_DIV   ),  
    .FBCLK_DIV                    ( FBKCLK_DIV   ),  

    .CLKC0_ENABLE                 ( "ENABLE"     ),  
    .CLKC1_ENABLE                 ( "ENABLE"     ),  
    .CLKC2_ENABLE                 ( "ENABLE"     ),  
    .CLKC3_ENABLE                 ( "ENABLE"     ),  
    .CLKC4_ENABLE                 ( "DISABLE"    ),  
    .CLKC5_ENABLE                 ( "DISABLE"    ),  
    .CLKC6_ENABLE                 ( "DISABLE"    ),  

    .CLKC0_DIV                    ( CLK0_DIV     ),  
    .CLKC1_DIV                    ( CLK1_DIV     ),  
    .CLKC2_DIV                    ( CLK2_DIV     ),  
    .CLKC3_DIV                    ( CLK3_DIV     ),  
    .CLKC4_DIV                    ( 1            ),  
    .CLKC5_DIV                    ( 1            ),  
    .CLKC6_DIV                    ( 1            ),  

    .CLKC0_DUTY_INT               ((CLK0_DIV+1)/2),  
    .CLKC1_DUTY_INT               ((CLK1_DIV+1)/2),  
    .CLKC2_DUTY_INT               ((CLK2_DIV+1)/2),  
    .CLKC3_DUTY_INT               ((CLK3_DIV+1)/2),  
    .CLKC4_DUTY_INT               ( 1            ),  
    .CLKC5_DUTY_INT               ( 1            ),  
    .CLKC6_DUTY_INT               ( 1            ),  

    .LPF_RES                      ( LPF_RES      ),  
    .LPF_CAP                      ( LPF_CAP      ),  
    .ICP_CUR                      ( ICP_CUR      ),  

    .CLKC0_FPHASE                 ( 0            ),  
    .CLKC1_FPHASE                 ( 0            ),  
    .CLKC2_FPHASE                 ( 0            ),  
    .CLKC3_FPHASE                 ( 0            ),  
    .CLKC4_FPHASE                 ( 0            ),  
    .CLKC5_FPHASE                 ( 0            ),  
    .CLKC6_FPHASE                 ( 0            ),  

    .CLKC0_FPHASE_RSTSEL          ( 0            ),  
    .CLKC1_FPHASE_RSTSEL          ( 0            ),  
    .CLKC2_FPHASE_RSTSEL          ( 0            ),  
    .CLKC3_FPHASE_RSTSEL          ( 0            ),  
    .CLKC4_FPHASE_RSTSEL          ( 0            ),  
    .CLKC5_FPHASE_RSTSEL          ( 0            ),  
    .CLKC6_FPHASE_RSTSEL          ( 0            ),  

    .CLKC0_CPHASE                 ( CLK0_DIV-1   ),  
    .CLKC1_CPHASE                 ( CLK1_DIV-1   ),  
    .CLKC2_CPHASE                 ( CLK2_DIV-1   ),  
    .CLKC3_CPHASE                 ( CLK3_DIV-1   ),  
    .CLKC4_CPHASE                 ( 0            ),  
    .CLKC5_CPHASE                 ( 0            ),  
    .CLKC6_CPHASE                 ( 0            ),  

    .PREDIV_MUXC0                 ( "VCO"        ),  
    .PREDIV_MUXC1                 ( "VCO"        ),  
    .PREDIV_MUXC2                 ( "VCO"        ),  
    .PREDIV_MUXC3                 ( "VCO"        ),  
    .PREDIV_MUXC4                 ( "VCO"        ),  
    .PREDIV_MUXC5                 ( "VCO"        ),  
    .PREDIV_MUXC6                 ( "VCO"        ),  

    .DIVOUT_MUXC0                 ( "DIV"        ),  
    .DIVOUT_MUXC1                 ( "DIV"        ),  
    .DIVOUT_MUXC2                 ( "DIV"        ),  
    .DIVOUT_MUXC3                 ( "DIV"        ),  
    .DIVOUT_MUXC4                 ( "DIV"        ),  
    .DIVOUT_MUXC5                 ( "DIV"        ),  
    .DIVOUT_MUXC6                 ( "DIV"        ),  

    .REFCLK_DET_BYP               ( "DISABLE"    ),  

    .FRAC_ENABLE                  ( FRAC         ),  
    .SDM_FRAC                     ( FRAC_SDM     ),  

    .PHASE_PATH_SEL               ( 0            ),  
    .DYN_PHASE_PATH_SEL           ( "DISABLE"    ),  
    .DYN_FPHASE_EN                ( "DISABLE"    ),  
    .DYN_CPHASE_EN                ( "DISABLE"    ),  

    .PLL_FASTLOOP                 ( FAST_LOOP    ),
    .CLKC0_FRAC_EN                ( "DISABLE"    ),  
    .CLKC0_FRAC                   ( 0            ),  
    .PI_OUT_SEL                   ( "NORMAL"     ),  
    .PI_FRAC_EN                   ( "DISABLE"    ),  
    .CLKC0_PI_SHIFT_EN            ( "DISABLE"    )   
) u_pll_inst (
 
    .refclk      ( refclk      ),  
    .refclk_rst  ( 1'b0        ),  

    .pllreset    ( reset       ),  
    .pllpd       ( 1'b0        ),  
    .wakeup      ( 1'b1        ),  

    .fbclk       ( fbclk       ),  
    .clkc_rst    ( 2'b00       ),  
    .clkc_en     ( clkc_en     ),  
    .clkc        ( clkc        ),  

    .lock        ( lock        ),  

    .drp_clk     ( 1'b0        ),  
    .drp_rstn    ( 1'b1        ),  
    .drp_sel     ( 1'b0        ),  
    .drp_rd      ( 1'b0        ),  
    .drp_wr      ( 1'b0        ),  
    .drp_addr    ( 8'h00       ),  
    .drp_wdata   ( 8'h00       ),  
    .drp_err     (             ),  
    .drp_rdy     (             ),  
    .drp_rdata   (             ),  

    .psdone      (             ),  
    .psclk       ( 1'b0        ),  
    .psdown      ( 1'b0        ),  
    .psstep      ( 1'b0        ),  
    .psclksel    ( 3'b000      ),  
    .cps_step    ( 1'b0        ),  

    .ssc_reset   ( 1'b1        ),  

    .scan_clk    ( 1'b0        ),  
    .scan_enable ( 1'b1        ),  
    .scan_mode   ( 1'b0        ),  
    .scan_resetn ( 1'b0        )   
);

endmodule
