// Frame ownership and stable reader leases.
// are historical package notes, not a full-project synthesis result here.

module frame_buffer_arbiter #(
    parameter FRAME_W   = 320,
    parameter FRAME_H   = 240,
    parameter TOTAL_PIX = FRAME_W * FRAME_H
) (
    input wire clk,
    input wire rst_n,

    input wire [23:0] wr_data,
    input wire        wr_valid,
    input wire        wr_frame_end,

    output wire [23:0] prev_data,
    input  wire        prev_read_en,

    input  wire [31:0] mem_frame_id,
    input  wire [31:0] mem_pixel_index,
    input  wire        mem_req_valid,
    output wire        mem_req_ready,
    output wire [23:0] mem_rgb,
    output reg         mem_rsp_valid,
    input  wire        mem_rsp_ready,
    output reg         mem_rsp_error,

    input  wire reader_flush,
    output wire rd_idle,

    input  wire        lease_valid,
    output reg         lease_gnt,
    output reg  [31:0] lease_frame_id,
    output reg  [15:0] lease_width,
    output reg  [15:0] lease_height,
    input  wire        lease_release,

    output reg [31:0] curr_frame_id,
    output reg [31:0] read_frame_id,

    output reg        drop_strobe,
    output reg [31:0] drop_frame_id
);

    localparam [15:0] FRAME_W16 = FRAME_W;
    localparam [15:0] FRAME_H16 = FRAME_H;

    reg         wr_buf_sel;

    wire        rd_buf_sel = ~wr_buf_sel;

    reg  [16:0] wr_addr;
    reg         write_overflow;
    wire [17:0] pixels_at_end = {1'b0, wr_addr} + (wr_valid ? 18'd1 : 18'd0);
    wire        complete_frame = !write_overflow && (pixels_at_end == TOTAL_PIX);

    reg         frame_disturbed;

    reg  [31:0] frame_counter;
    reg         frame_ids_exhausted;

    reg         is_locked;
    reg         release_pending;
    reg  [31:0] locked_frame_id;
    reg         locked_buf_sel;

    reg         req_pending;
    reg         req_err;
    reg  [16:0] req_addr;

    assign rd_idle = !req_pending && !mem_rsp_valid;

    assign mem_req_ready = rst_n && rd_idle && !reader_flush && !lease_release && !release_pending;

    wire [15:0] wr_gray_raw =
        ({8'd0, wr_data[23:16]} << 6) + ({8'd0, wr_data[23:16]} << 3) +
        ({8'd0, wr_data[23:16]} << 2) +  {8'd0, wr_data[23:16]} +
        ({8'd0, wr_data[15:8]}  << 7) + ({8'd0, wr_data[15:8]}  << 4) +
        ({8'd0, wr_data[15:8]}  << 2) + ({8'd0, wr_data[15:8]}  << 1) +
        ({8'd0, wr_data[7:0]}   << 4) + ({8'd0, wr_data[7:0]}   << 3) +
        ({8'd0, wr_data[7:0]}   << 2) +  {8'd0, wr_data[7:0]};
    wire [7:0] wr_gray = wr_gray_raw[15:8];

    wire ram0_we = wr_valid && (wr_addr < TOTAL_PIX) && (wr_buf_sel == 1'b0);
    wire ram1_we = wr_valid && (wr_addr < TOTAL_PIX) && (wr_buf_sel == 1'b1);

    wire [17:0] pf_raw = wr_valid ? ({1'b0, wr_addr} + 18'd1) : {1'b0, wr_addr};
    wire [16:0] pf_addr = (pf_raw >= TOTAL_PIX) ? 17'd0 : pf_raw[16:0];

    wire roi_hold = req_pending || mem_rsp_valid;
    wire [16:0] rd_addr = roi_hold ? req_addr : pf_addr;

    wire [7:0] ram0_q, ram1_q;

    frame_ram_sdp #(
        .TOTAL_PIX(TOTAL_PIX)
    ) u_ram0 (
        .clk  (clk),
        .we   (ram0_we),
        .waddr(wr_addr),
        .wdata(wr_gray),
        .raddr(rd_addr),
        .rdata(ram0_q)
    );

    frame_ram_sdp #(
        .TOTAL_PIX(TOTAL_PIX)
    ) u_ram1 (
        .clk  (clk),
        .we   (ram1_we),
        .waddr(wr_addr),
        .wdata(wr_gray),
        .raddr(rd_addr),
        .rdata(ram1_q)
    );

    reg roi_read_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) roi_read_d <= 1'b0;
        else roi_read_d <= roi_hold;
    end

    wire [7:0] pf_gray = rd_buf_sel ? ram1_q : ram0_q;
    assign prev_data = roi_read_d ? 24'd0 : {pf_gray, pf_gray, pf_gray};

    wire [7:0] roi_gray = locked_buf_sel ? ram1_q : ram0_q;
    assign mem_rgb = req_err ? 24'd0 : {roi_gray, roi_gray, roi_gray};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) frame_disturbed <= 1'b0;
        else if (wr_frame_end) frame_disturbed <= 1'b0;
        else if (wr_valid && (roi_hold || roi_read_d)) frame_disturbed <= 1'b1;
    end

    wire publish_now = wr_frame_end && !frame_ids_exhausted && complete_frame && !is_locked &&
                       !frame_disturbed && !(wr_valid && (roi_hold || roi_read_d)) &&
                       !(lease_valid && read_frame_id != 32'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr             <= 17'd0;
            write_overflow      <= 1'b0;
            wr_buf_sel          <= 1'b0;
            frame_counter       <= 32'd1;
            frame_ids_exhausted <= 1'b0;
            curr_frame_id       <= 32'd1;
            read_frame_id       <= 32'd0;
            drop_strobe         <= 1'b0;
            drop_frame_id       <= 32'd0;
        end else begin
            if (wr_valid) begin
                if (wr_addr < TOTAL_PIX) wr_addr <= wr_addr + 1'b1;
                else write_overflow <= 1'b1;
            end

            drop_strobe <= 1'b0;

            if (wr_frame_end) begin
                if (frame_counter == 32'hffffffff) frame_ids_exhausted <= 1;
                else begin
                    frame_counter <= frame_counter + 1'b1;
                    curr_frame_id <= frame_counter + 1'b1;
                end
                wr_addr <= 17'd0;
                write_overflow <= 1'b0;
                if (publish_now) begin

                    wr_buf_sel    <= ~wr_buf_sel;
                    read_frame_id <= frame_counter;

                end else begin

                    drop_strobe   <= 1'b1;
                    drop_frame_id <= frame_counter;
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_locked       <= 1'b0;
            release_pending <= 1'b0;
            lease_gnt       <= 1'b0;
            lease_frame_id  <= 32'd0;
            lease_width     <= 16'd0;
            lease_height    <= 16'd0;
            locked_frame_id <= 32'd0;
            locked_buf_sel  <= 1'b0;
        end else begin
            lease_gnt <= 1'b0;

            if (lease_valid && !is_locked && rd_idle && !lease_release && !reader_flush &&
                read_frame_id != 32'd0 && !publish_now) begin
                is_locked       <= 1'b1;
                lease_gnt       <= 1'b1;
                locked_frame_id <= read_frame_id;
                locked_buf_sel  <= rd_buf_sel;
                lease_frame_id  <= read_frame_id;
                lease_width     <= FRAME_W16;
                lease_height    <= FRAME_H16;
            end

            if (lease_release && is_locked) release_pending <= 1'b1;
            if (is_locked && (lease_release || release_pending) &&
                (rd_idle || reader_flush || (mem_rsp_valid && mem_rsp_ready))) begin
                is_locked <= 1'b0;
                release_pending <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_error <= 1'b0;
            req_pending   <= 1'b0;
            req_err       <= 1'b0;
            req_addr      <= 17'd0;
        end else if (reader_flush) begin

            req_pending   <= 1'b0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_error <= 1'b0;
        end else begin
            if (!req_pending && !mem_rsp_valid) begin
                if (mem_req_valid && mem_req_ready) begin
                    if (!is_locked ||
                        mem_frame_id != locked_frame_id ||
                        mem_pixel_index >= TOTAL_PIX) begin
                        req_pending <= 1'b1;
                        req_addr    <= 17'd0;
                        req_err     <= 1'b1;
                    end else begin
                        req_pending <= 1'b1;
                        req_addr    <= mem_pixel_index[16:0];
                        req_err     <= 1'b0;
                    end
                end
            end

            if (req_pending) begin
                req_pending   <= 1'b0;
                mem_rsp_valid <= 1'b1;
                mem_rsp_error <= req_err;

            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                mem_rsp_valid <= 1'b0;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if (TOTAL_PIX<1 || TOTAL_PIX>131071 || FRAME_W<1 || FRAME_H<1 ||
            FRAME_W>65535 || FRAME_H>65535 || TOTAL_PIX!=FRAME_W*FRAME_H)
            $fatal(1, "Invalid frame_buffer_arbiter geometry");
    end
    // synthesis translate_on
endmodule

module frame_ram_sdp #(
    parameter TOTAL_PIX  = 76800,
    parameter BANK_DEPTH = 16384
) (
    input  wire        clk,
    input  wire        we,
    input  wire [16:0] waddr,
    input  wire [ 7:0] wdata,
    input  wire [16:0] raddr,
    output wire [ 7:0] rdata
);

    localparam integer BANKS   = (TOTAL_PIX + BANK_DEPTH - 1) / BANK_DEPTH;
    localparam integer AW_BANK = $clog2(BANK_DEPTH);
    localparam integer SEL_W   = (BANKS <= 1) ? 1 : $clog2(BANKS);

    wire [SEL_W-1:0] wr_sel = waddr[AW_BANK+:SEL_W];
    wire [AW_BANK-1:0] wr_off = waddr[AW_BANK-1:0];
    wire [SEL_W-1:0] rd_sel = raddr[AW_BANK+:SEL_W];
    wire [AW_BANK-1:0] rd_off = raddr[AW_BANK-1:0];

    wire [7:0] bank_q[0:BANKS-1];

    genvar b;
    generate
        for (b = 0; b < BANKS; b = b + 1) begin : g_bank
            frame_ram_bank #(
                .DEPTH ((TOTAL_PIX-b*BANK_DEPTH<BANK_DEPTH)?TOTAL_PIX-b*BANK_DEPTH:BANK_DEPTH),
                .AW(AW_BANK)
            ) u_bank (
                .clk  (clk),
                .we   (we && (wr_sel == b[SEL_W-1:0])),
                .waddr(wr_off),
                .wdata(wdata),
                .raddr(rd_off),
                .rdata(bank_q[b])
            );
        end
    endgenerate

    reg [SEL_W-1:0] rd_sel_d;
    always @(posedge clk) rd_sel_d <= rd_sel;

    assign rdata = bank_q[rd_sel_d];

endmodule

module frame_ram_bank #(
    parameter DEPTH = 16384,
    parameter AW    = 14
) (
    input  wire          clk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [   7:0] wdata,
    input  wire [AW-1:0] raddr,
    output reg  [   7:0] rdata
);

    (* ram_style = "bram" *) reg [7:0] mem[0:DEPTH-1];

    integer i;
    initial begin

        for (i = 0; i < (DEPTH + 1) / 2; i = i + 1) begin
            mem[i] = 8'd0;
            if (i + (DEPTH + 1) / 2 < DEPTH) mem[i+(DEPTH+1)/2] = 8'd0;
        end
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;

        rdata <= mem[raddr];
    end

endmodule
