`timescale 1ns / 1ps
module soft_fifo_al_f58e8b3e1f3d #(
    parameter DATA_WIDTH_W = 8,
    parameter DATA_WIDTH_R = 8,
    parameter ADDR_WIDTH_W = 8,
    parameter ADDR_WIDTH_R = 8,
    parameter AL_FULL_NUM = 8,
    parameter AL_EMPTY_NUM = 8,
    parameter SHOW_AHEAD_EN = 1'b0,
    parameter OUTREG_EN = "NOREG"
) (

    input rst,
    input clk,
    input we,
    input [(DATA_WIDTH_W - 1):0] di,
    input re,
    output [(DATA_WIDTH_R - 1):0] dout,
    output reg valid,
    output full_flag,
    output empty_flag,
    output afull,
    output aempty,
    output [(ADDR_WIDTH_W - 1):0] wrusedw,
    output [(ADDR_WIDTH_R - 1):0] rdusedw
)  /* fehdl keep_hierarchy="true" */;

    localparam FULL_NUM = {ADDR_WIDTH_W{1'b1}};

    reg asy_rst0;
    reg asy_rst1;
    wire asy_rst;
    reg [(ADDR_WIDTH_W - 1):0] wr_addr_r1;
    reg [(ADDR_WIDTH_W - 1):0] wr_addr;
    reg [(ADDR_WIDTH_R - 1):0] rd_addr;
    wire wr_en_s;
    wire rd_en_s;
    reg [(ADDR_WIDTH_W - 1):0] shift_rdaddr;
    reg [(ADDR_WIDTH_R - 1):0] shift_wraddr;
    wire [(ADDR_WIDTH_W - 1):0] wr_addr_diff;
    wire [(ADDR_WIDTH_R - 1):0] rd_addr_diff;
    reg empty_flag_r1;
    reg empty_flag_r2;
    reg re_r1;
    reg re_r2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asy_rst0 <= 1'b1;
            asy_rst1 <= 1'b1;
        end else begin
            asy_rst0 <= 1'b0;
            asy_rst1 <= asy_rst0;
        end
    end
    assign asy_rst = asy_rst1;

    assign wr_en_s = ((!full_flag) & we);
    assign rd_en_s = ((!empty_flag) & re);

    always @(posedge clk or posedge asy_rst) begin
        if ((asy_rst == 1'b1)) wr_addr <= 'b0;
        else if (wr_en_s) wr_addr <= (wr_addr + 'b01);
    end

    always @(posedge clk or posedge asy_rst) begin
        if ((asy_rst == 1'b1)) rd_addr <= 'b0;
        else if (rd_en_s) rd_addr <= (rd_addr + 'b01);
    end

    always @(posedge clk or posedge asy_rst) begin
        if ((asy_rst == 1'b1)) begin
            wr_addr_r1 <= 'b0;
        end else begin
            wr_addr_r1 <= wr_addr;
        end
    end
    always @(*) begin
        if ((ADDR_WIDTH_R >= ADDR_WIDTH_W)) begin
            shift_rdaddr = (rd_addr >> (ADDR_WIDTH_R - ADDR_WIDTH_W));
            shift_wraddr = (wr_addr_r1 << (ADDR_WIDTH_R - ADDR_WIDTH_W));
        end else begin
            shift_rdaddr = (rd_addr << (ADDR_WIDTH_W - ADDR_WIDTH_R));
            shift_wraddr = (wr_addr_r1 >> (ADDR_WIDTH_W - ADDR_WIDTH_R));
        end
    end

    assign wr_addr_diff = (wr_addr - shift_rdaddr);
    assign rd_addr_diff = (shift_wraddr - rd_addr);

    assign full_flag = ((wr_addr_diff >= FULL_NUM) ? 1'b1 : 1'b0);

    assign afull = ((wr_addr_diff >= AL_FULL_NUM) ? 1'b1 : 1'b0);

    assign empty_flag = ((rd_addr_diff == 5'b0) ? 1'b1 : 1'b0);

    assign aempty = ((rd_addr_diff <= AL_EMPTY_NUM) ? 1'b1 : 1'b0);

    assign wrusedw = wr_addr_diff;

    assign rdusedw = rd_addr_diff;

    always @(posedge clk or posedge asy_rst) begin
        if ((asy_rst == 1'b1)) begin
            empty_flag_r1 <= 1'b1;
            empty_flag_r2 <= 1'b1;
        end else begin
            empty_flag_r1 <= empty_flag;
            empty_flag_r2 <= empty_flag_r1;
        end
    end

    always @(posedge clk or posedge asy_rst) begin
        if ((asy_rst == 1'b1)) begin
            re_r1 <= 1'b0;
            re_r2 <= 1'b0;
        end else begin
            re_r1 <= rd_en_s;
            re_r2 <= re_r1;
        end
    end

    always @(*) begin
        if ((SHOW_AHEAD_EN && (OUTREG_EN == "NOREG"))) valid = (!empty_flag);
        else if (((!SHOW_AHEAD_EN) && (OUTREG_EN == "OUTREG"))) valid = (re_r2 & (!empty_flag_r2));
        else valid = (re_r1 & (!empty_flag_r1));
    end

    ram_infer_f58e8b3e1f3d #(
        .DATAWIDTH_A(DATA_WIDTH_W),
        .ADDRWIDTH_A(ADDR_WIDTH_W),
        .DATAWIDTH_B(DATA_WIDTH_R),
        .ADDRWIDTH_B(ADDR_WIDTH_R),
        .RESETMODE_A("ASYNC"),
        .RESETMODE_B("ASYNC"),
        .MODE("SDP"),
        .REGMODE_B(OUTREG_EN)
    ) ram_inst (
        .clka (clk),
        .rsta (asy_rst),
        .cea  (1),
        .wea  (wr_en_s),
        .ocea (0),
        .dia  (di),
        .addra(wr_addr),
        .clkb (clk),
        .rstb (asy_rst),
        .ceb  ((SHOW_AHEAD_EN | rd_en_s)),
        .web  (0),
        .oceb (1'b1),
        .addrb((rd_addr + (SHOW_AHEAD_EN & rd_en_s))),
        .dob  (dout)
    );
endmodule

`timescale 1ns / 1ps
module ram_infer_f58e8b3e1f3d (
    clka,
    rsta,
    cea,
    ocea,
    wea,
    dia,
    addra,
    doa,
    clkb,
    rstb,
    ceb,
    oceb,
    web,
    dib,
    addrb,
    dob
);

    parameter MODE = "SDP";
    parameter BYTE_SIZE = 8;
    parameter INIT_FILE = "";
    parameter INIT_VALUE = 0;
    parameter USE_BYTE_WEA = 0;
    parameter DATAWIDTH_A = 32;
    parameter WEA_WIDTH = ((USE_BYTE_WEA == 0) ? 1 : (DATAWIDTH_A / BYTE_SIZE));
    parameter REGMODE_A = "NOREG";
    parameter RESETMODE_A = "ASYNC";
    parameter INITVAL_A = {DATAWIDTH_A{1'b0}};
    parameter WRITEMODE_A = "NORMAL";
    parameter ADDRWIDTH_A = 5;
    parameter DATADEPTH_A = (2 ** ADDRWIDTH_A);
    parameter SSROVERCE_A = "ENABLE";
    parameter USE_BYTE_WEB = USE_BYTE_WEA;
    parameter DATAWIDTH_B = DATAWIDTH_A;
    parameter WEB_WIDTH = ((USE_BYTE_WEB == 0) ? 1 : (DATAWIDTH_B / BYTE_SIZE));
    parameter REGMODE_B = "NOREG";
    parameter RESETMODE_B = "ASYNC";
    parameter INITVAL_B = {DATAWIDTH_B{1'b0}};
    parameter WRITEMODE_B = "NORMAL";
    parameter ADDRWIDTH_B = ADDRWIDTH_A;
    parameter DATADEPTH_B = (2 ** ADDRWIDTH_B);
    parameter SSROVERCE_B = "ENABLE";

    input clka, rsta, cea, ocea;
    input [(WEA_WIDTH - 1):0] wea;
    input [(DATAWIDTH_A - 1):0] dia;
    input [(ADDRWIDTH_A - 1):0] addra;
    input clkb, rstb, ceb, oceb;
    input [(WEB_WIDTH - 1):0] web;
    input [(DATAWIDTH_B - 1):0] dib;
    input [(ADDRWIDTH_B - 1):0] addrb;

    output [(DATAWIDTH_A - 1):0] doa;
    output [(DATAWIDTH_B - 1):0] dob;

    localparam MIN_WIDTH = ((DATAWIDTH_A > DATAWIDTH_B) ? DATAWIDTH_B : DATAWIDTH_A);
    localparam MAX_DEPTH = ((DATADEPTH_A > DATADEPTH_B) ? DATADEPTH_A : DATADEPTH_B);
    localparam WIDTHRATIO_A = (DATAWIDTH_A / MIN_WIDTH);
    localparam WIDTHRATIO_B = (DATAWIDTH_B / MIN_WIDTH);
    reg [(MIN_WIDTH - 1):0] memory [(MAX_DEPTH - 1):0] ;  /* fehdl force_ram=1, ram_style="bram_fast" */
    reg [(DATAWIDTH_A - 1):0] doa_tmp = INITVAL_A;
    reg [(DATAWIDTH_B - 1):0] dob_tmp = INITVAL_B;
    reg [(DATAWIDTH_A - 1):0] doa_tmp2 = INITVAL_A;
    reg [(DATAWIDTH_B - 1):0] dob_tmp2 = INITVAL_B;
    integer i;
    integer j;

    initial begin
        for (i = 0; (i < 128); i = (i + 1)) begin
            for (j = 0; (j < 8192); j = (j + 1)) begin
                if ((((i * 8192) + j) < MAX_DEPTH)) begin
                    memory[((i*8192)+j)] = INIT_VALUE;
                end else begin
                    j = 8192;
                    i = 128;
                end
            end
        end
    end

    always @(posedge clka) begin
        if (cea) begin
            write_a(addra, dia, wea);
        end
    end
    always @(posedge clkb) begin
        if (ceb) begin
            if ((MODE == "DP")) begin
                write_b(addrb, dib, web);
            end
        end
    end
    reg rsta_p1 = 1, rsta_p2 = 1;
    wire rsta_p3 = ((rsta_p2 | rsta_p1) | rsta);
    always @(posedge clka or posedge rsta) begin
        if (rsta) begin
            rsta_p1 <= 1;
        end else begin
            rsta_p1 <= 0;
        end
    end
    always @(negedge clka) begin
        rsta_p2 <= rsta_p1;
    end

    wire sync_rsta = ((RESETMODE_A == "SYNC") && rsta);
    wire async_rsta = ((RESETMODE_A == "ASYNC") ? rsta : ((RESETMODE_A == "ARSR") ? rsta_p3 : 0));
    wire ssroverce_a = ((SSROVERCE_A == "ENABLE") && sync_rsta);
    wire ceoverssr_a = ((SSROVERCE_A == "DISABLE") && sync_rsta);
    always @(posedge clka or posedge async_rsta) begin
        if (async_rsta) begin
            doa_tmp2 <= INITVAL_A;
        end else if (ssroverce_a) begin
            doa_tmp2 <= INITVAL_A;
        end else if (ocea) begin
            if (ceoverssr_a) begin
                doa_tmp2 <= INITVAL_A;
            end else begin
                doa_tmp2 <= doa_tmp;
            end
        end
    end
    always @(posedge clka or posedge async_rsta) begin
        if (async_rsta) begin
            doa_tmp <= INITVAL_A;
        end else if (sync_rsta) begin
            doa_tmp <= INITVAL_A;
        end else begin
            if (cea) begin
                if (((MODE == "SP") || (MODE == "DP"))) begin
                    read_a(addra, dia, wea);
                end
            end
        end
    end
    reg rstb_p1 = 1, rstb_p2 = 1;
    wire rstb_p3 = ((rstb_p1 | rstb_p2) | rstb);
    always @(posedge clkb or posedge rstb) begin
        if (rstb) begin
            rstb_p1 <= 1;
        end else begin
            rstb_p1 <= 0;
        end
    end
    always @(negedge clkb) begin
        rstb_p2 <= rstb_p1;
    end
    wire sync_rstb = ((RESETMODE_B == "SYNC") && rstb);
    wire async_rstb = ((RESETMODE_B == "ASYNC") ? rstb : ((RESETMODE_B == "ARSR") ? rstb_p3 : 0));
    wire ssroverce_b = ((SSROVERCE_B == "ENABLE") && sync_rstb);
    wire ceoverssr_b = ((SSROVERCE_B == "DISABLE") && sync_rstb);
    always @(posedge clkb or posedge async_rstb) begin
        if (async_rstb) begin
            dob_tmp2 <= INITVAL_B;
        end else if (ssroverce_b) begin
            dob_tmp2 <= INITVAL_B;
        end else if (oceb) begin
            if (ceoverssr_b) begin
                dob_tmp2 <= INITVAL_B;
            end else begin
                dob_tmp2 <= dob_tmp;
            end
        end
    end
    always @(posedge clkb or posedge async_rstb) begin
        if (async_rstb) begin
            dob_tmp <= INITVAL_B;
        end else if (sync_rstb) begin
            dob_tmp <= INITVAL_B;
        end else begin
            if (ceb) begin
                if ((MODE == "DP")) begin
                    read_b(addrb, dib, web);
                end else if ((MODE == "SDP")) begin
                    read_b(addrb, dib, 1'b0);
                end
            end
        end
    end
    assign doa = ((REGMODE_A == "OUTREG") ? doa_tmp2 : doa_tmp);
    assign dob = ((REGMODE_B == "OUTREG") ? dob_tmp2 : dob_tmp);
    task write_a(input reg [(ADDRWIDTH_A - 1):0] addr, input reg [(DATAWIDTH_A - 1):0] data,

                 input reg [(WEA_WIDTH - 1):0] we);
        integer i, j;
        begin
            if ((USE_BYTE_WEA != 0)) begin
                for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                    for (j = 0; (j < (WEA_WIDTH / WIDTHRATIO_A)); j = (j + 1)) begin
                        if (we[(((i*WEA_WIDTH)/WIDTHRATIO_A)+j)]) begin
                            memory[((addr * WIDTHRATIO_A) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] <=  data[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else begin
                if (we) begin
                    for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                        memory[((addr*WIDTHRATIO_A)+i)] <= data[(i*MIN_WIDTH)+:MIN_WIDTH];
                    end
                end
            end
        end
    endtask
    task write_b(input reg [(ADDRWIDTH_B - 1):0] addr, input reg [(DATAWIDTH_B - 1):0] data,

                 input reg [(WEB_WIDTH - 1):0] we);
        integer i, j;
        begin
            if ((USE_BYTE_WEB != 0)) begin
                for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                    for (j = 0; (j < (WEB_WIDTH / WIDTHRATIO_B)); j = (j + 1)) begin
                        if (we[(((i*WEB_WIDTH)/WIDTHRATIO_B)+j)]) begin
                            memory[((addr * WIDTHRATIO_B) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] <=  data[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else begin
                if (we) begin
                    for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                        memory[((addr*WIDTHRATIO_B)+i)] <= data[(i*MIN_WIDTH)+:MIN_WIDTH];
                    end
                end
            end
        end
    endtask
    task read_a(input reg [(ADDRWIDTH_A - 1):0] addr, input reg [(DATAWIDTH_A - 1):0] data,

                input reg [(WEA_WIDTH - 1):0] we);
        integer i, j;
        if ((USE_BYTE_WEA != 0)) begin
            if ((WRITEMODE_A == "NORMAL")) begin
                for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                    for (j = 0; (j < (WEA_WIDTH / WIDTHRATIO_A)); j = (j + 1)) begin
                        if ((!we[(((i*WEA_WIDTH)/WIDTHRATIO_A)+j)])) begin
                            doa_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  memory[((addr * WIDTHRATIO_A) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else if ((WRITEMODE_A == "WRITETHROUGH")) begin
                for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                    for (j = 0; (j < (WEA_WIDTH / WIDTHRATIO_A)); j = (j + 1)) begin
                        if (we[(((i*WEA_WIDTH)/WIDTHRATIO_A)+j)]) begin
                            doa_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  data[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] ;
                        end else begin
                            doa_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  memory[((addr * WIDTHRATIO_A) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else begin
                for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                    doa_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_A)+i)];
                end
            end
        end else begin
            if ((WRITEMODE_A == "NORMAL")) begin
                if ((!we[0])) begin
                    for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                        doa_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_A)+i)];
                    end
                end
            end else if ((WRITEMODE_A == "WRITETHROUGH")) begin
                if (we[0]) begin
                    doa_tmp <= data;
                end else begin
                    for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                        doa_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_A)+i)];
                    end
                end
            end else begin
                for (i = 0; (i < WIDTHRATIO_A); i = (i + 1)) begin
                    doa_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_A)+i)];
                end
            end
        end
    endtask
    task read_b(input reg [(ADDRWIDTH_B - 1):0] addr, input reg [(DATAWIDTH_B - 1):0] data,

                input reg [(WEB_WIDTH - 1):0] we);
        integer i, j;
        if ((USE_BYTE_WEB != 0)) begin
            if ((WRITEMODE_B == "NORMAL")) begin
                for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                    for (j = 0; (j < (WEB_WIDTH / WIDTHRATIO_B)); j = (j + 1)) begin
                        if ((!we[(((i*WEB_WIDTH)/WIDTHRATIO_B)+j)])) begin
                            dob_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  memory[((addr * WIDTHRATIO_B) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else if ((WRITEMODE_B == "WRITETHROUGH")) begin
                for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                    for (j = 0; (j < (WEB_WIDTH / WIDTHRATIO_B)); j = (j + 1)) begin
                        if (we[(((i*WEB_WIDTH)/WIDTHRATIO_B)+j)]) begin
                            dob_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  data[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] ;
                        end else begin
                            dob_tmp[((i * MIN_WIDTH) + (j * BYTE_SIZE)) +: BYTE_SIZE] <=  memory[((addr * WIDTHRATIO_B) + i)][(j * BYTE_SIZE) +: BYTE_SIZE] ;
                        end
                    end
                end
            end else begin
                for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                    dob_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_B)+i)];
                end
            end
        end else begin
            if ((WRITEMODE_B == "NORMAL")) begin
                if ((!we[0])) begin
                    for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                        dob_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_B)+i)];
                    end
                end
            end else if ((WRITEMODE_B == "WRITETHROUGH")) begin
                if (we[0]) begin
                    dob_tmp <= data;
                end else begin
                    for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                        dob_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_B)+i)];
                    end
                end
            end else begin
                for (i = 0; (i < WIDTHRATIO_B); i = (i + 1)) begin
                    dob_tmp[(MIN_WIDTH*i)+:MIN_WIDTH] <= memory[((addr*WIDTHRATIO_B)+i)];
                end
            end
        end
    endtask
endmodule
