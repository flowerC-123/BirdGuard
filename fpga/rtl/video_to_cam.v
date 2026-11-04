module video_to_cam #(
    parameter H_DIV = 4,
    V_DIV = 3,
    OUT_W = 320,
    OUT_H = 240,
    PIX_DIV = 10,
    KEEP_RGB = 0,
    parameter FIFO_AW = 9,
    BLANK_TH = 1024,
    DROP_TH = 256,
    IDLE_RST = 100000
) (
    input wire vin_clk,
    vin_rst_n,
    vin_de,
    input wire [23:0] vin_data,
    input wire cam_clk,
    cam_rst_n,
    output reg [23:0] cam_pixel,
    output reg cam_valid,
    cam_frame_start,
    cam_frame_end,
    output wire fifo_full,
    frame_drop,
    output wire [15:0] frame_cnt
);
    localparam DW = KEEP_RGB ? 24 : 8;
    localparam DEPTH = (1 << FIFO_AW), PIXMAX = OUT_W * OUT_H;
    localparam SOURCE_W = OUT_W * H_DIV, SOURCE_H = OUT_H * V_DIV;

    (* async_reg="true" *) reg [1:0] vin_reset_sync, cam_reset_sync;
    always @(posedge vin_clk or negedge vin_rst_n)
        if (!vin_rst_n) vin_reset_sync <= 0;
        else vin_reset_sync <= {vin_reset_sync[0], 1'b1};
    always @(posedge cam_clk or negedge cam_rst_n)
        if (!cam_rst_n) cam_reset_sync <= 0;
        else cam_reset_sync <= {cam_reset_sync[0], 1'b1};
    wire vin_ready = vin_reset_sync[1], cam_ready = cam_reset_sync[1];

    reg vin_peer_reset = 1'b1, cam_peer_reset = 1'b1;

    always @(posedge vin_clk or negedge cam_rst_n)
        if (!cam_rst_n) vin_peer_reset <= 1'b1;
        else if (!vin_ready) vin_peer_reset <= 1'b0;
    always @(posedge cam_clk or negedge vin_rst_n)
        if (!vin_rst_n) cam_peer_reset <= 1'b1;
        else if (!cam_ready) cam_peer_reset <= 1'b0;

    (* ram_style="dram" *) reg [DW+1:0] mem[0:DEPTH-1];
    reg [FIFO_AW:0] wptr_bin, wptr_gry, rptr_bin, rptr_gry;
    (* async_reg="true" *) reg [FIFO_AW:0] rptr_gry_s1, rptr_gry_s2;
    (* async_reg="true" *) reg [FIFO_AW:0] wptr_gry_s1, wptr_gry_s2;
    function [FIFO_AW:0] bin2gry;
        input [FIFO_AW:0] b;
        begin
            bin2gry = b ^ (b >> 1);
        end
    endfunction
    function [FIFO_AW:0] gry2bin;
        input [FIFO_AW:0] g;
        integer i;
        begin
            gry2bin[FIFO_AW] = g[FIFO_AW];
            for (i = FIFO_AW - 1; i >= 0; i = i - 1) gry2bin[i] = gry2bin[i+1] ^ g[i];
        end
    endfunction
    function [7:0] gray;
        input [7:0] r, g, b;
        reg [15:0] sum;
        begin
            sum=({8'd0,r}<<6)+({8'd0,r}<<3)+({8'd0,r}<<2)+{8'd0,r}
      +({8'd0,g}<<7)+({8'd0,g}<<4)+({8'd0,g}<<2)+({8'd0,g}<<1)
      +({8'd0,b}<<4)+({8'd0,b}<<3)+({8'd0,b}<<2)+{8'd0,b};
            gray = sum[15:8];
        end
    endfunction
    wire full = (wptr_gry == {~rptr_gry_s2[FIFO_AW:FIFO_AW-1], rptr_gry_s2[FIFO_AW-2:0]});
    wire empty = (rptr_gry == wptr_gry_s2);
    wire [FIFO_AW:0] used = wptr_bin - gry2bin(rptr_gry_s2);
    assign fifo_full = full;
    reg de_d, frame_active, drop_q, overflow_q, source_open, tail_pending;
    reg [DW-1:0] tail_gray;
    reg [15:0] blank_cnt, col, row;
    reg [16:0] sample_count;
    reg [23:0] acc0, acc1, acc2;
    wire row_start = vin_de && !de_d;
    wire sof = row_start && (blank_cnt >= BLANK_TH);
    wire row_end = !vin_de && de_d;
    wire source_eof = source_open && !vin_de && (blank_cnt >= BLANK_TH - 1);

    wire source_geometry_done=row_end ? ((row==SOURCE_H-1)&&(col==SOURCE_W)) : (row==SOURCE_H);
    wire [15:0] row_now = sof ? 16'd0 : row;
    wire sample=vin_de&&frame_active&&(row_now<OUT_H*V_DIV)&&
             ((row_now%V_DIV)==0)&&(col<OUT_W*4)&&(col[1:0]==3)&&
             (sample_count<PIXMAX);
    wire [9:0] sum_r={2'd0,acc0[23:16]}+{2'd0,acc1[23:16]}+
                  {2'd0,acc2[23:16]}+{2'd0,vin_data[23:16]};
    wire [9:0] sum_g={2'd0,acc0[15:8]}+{2'd0,acc1[15:8]}+
                  {2'd0,acc2[15:8]}+{2'd0,vin_data[15:8]};
    wire [9:0] sum_b={2'd0,acc0[7:0]}+{2'd0,acc1[7:0]}+
                  {2'd0,acc2[7:0]}+{2'd0,vin_data[7:0]};
    wire [DW-1:0] sampled_pixel = KEEP_RGB ? {sum_r[9:2], sum_g[9:2], sum_b[9:2]} : gray(
        sum_r[9:2], sum_g[9:2], sum_b[9:2]
    );
    reg fault_cam;
    (* async_reg="true" *) reg fault_v1, fault_v2, overflow_c1, overflow_c2;
    assign frame_drop = drop_q || overflow_q || fault_v2 || vin_peer_reset;
    always @(posedge vin_clk or negedge vin_ready) begin
        if (!vin_ready) begin
            wptr_bin <= 0;
            wptr_gry <= 0;
            rptr_gry_s1 <= 0;
            rptr_gry_s2 <= 0;
            de_d <= 0;
            blank_cnt <= 0;
            col <= 0;
            row <= 0;
            sample_count <= 0;
            frame_active <= 0;
            drop_q <= 0;
            overflow_q <= 0;
            source_open <= 0;
            tail_pending <= 0;
            tail_gray <= 0;
            acc0 <= 0;
            acc1 <= 0;
            acc2 <= 0;
            fault_v1 <= 0;
            fault_v2 <= 0;
        end else begin
            rptr_gry_s1 <= rptr_gry;
            rptr_gry_s2 <= rptr_gry_s1;
            fault_v1 <= fault_cam;
            fault_v2 <= fault_v1;
            de_d <= vin_de;
            if (vin_de) begin
                blank_cnt <= 0;
                if (col != 16'hffff) col <= col + 1'b1;
            end else begin
                col <= 0;
                if (blank_cnt != 16'hffff) blank_cnt <= blank_cnt + 1'b1;
            end
            if (sof) begin
                if (source_open && frame_active) overflow_q <= 1;
                row <= 0;
                sample_count <= 0;
                source_open <= 1;
                frame_active <= (used < DROP_TH) && !overflow_q && !fault_v2 && !vin_peer_reset;
                drop_q <= (used >= DROP_TH);
            end else if (row_end) begin
                if (row != 16'hffff) row <= row + 1'b1;
                if (frame_active && (row >= SOURCE_H || col != SOURCE_W)) overflow_q <= 1;
            end
            if (vin_de)
                case (col[1:0])
                    0: acc0 <= vin_data;
                    1: acc1 <= vin_data;
                    2: acc2 <= vin_data;
                    default: ;
                endcase
            if (sample && !overflow_q && !fault_v2 && !vin_peer_reset) begin
                if (sample_count == PIXMAX - 1) begin
                    tail_gray <= sampled_pixel;
                    tail_pending <= 1;
                    sample_count <= sample_count + 1'b1;
                end else if (full) begin
                    overflow_q <= 1;
                    drop_q <= 1;
                end else begin
                    mem[wptr_bin[FIFO_AW-1:0]] <= {sample_count == 0, 1'b0, sampled_pixel};
                    wptr_bin <= wptr_bin + 1'b1;
                    wptr_gry <= bin2gry(wptr_bin + 1'b1);
                    sample_count <= sample_count + 1'b1;
                end
            end

            if (source_eof) begin
                source_open  <= 0;
                frame_active <= 0;
                if (frame_active && !overflow_q && !fault_v2 && !vin_peer_reset) begin
                    if(!source_geometry_done||sample_count!=PIXMAX||!tail_pending||full)begin
                        overflow_q <= 1;
                        drop_q <= 1;
                    end else begin
                        mem[wptr_bin[FIFO_AW-1:0]] <= {PIXMAX == 1, 1'b1, tail_gray};
                        wptr_bin <= wptr_bin + 1'b1;
                        wptr_gry <= bin2gry(wptr_bin + 1'b1);
                        tail_pending <= 0;
                    end
                end
            end
        end
    end
    reg [7:0] div;
    reg pop_d, in_frame;
    reg [DW+1:0] dout;
    reg [16:0] pix_cnt;
    reg [23:0] idle_cnt;
    reg [15:0] frame_cnt_q;
    wire pop = (div == 0) && !empty && !fault_cam && !overflow_c2 && !cam_peer_reset;
    wire [16:0] index_now = dout[DW+1] ? 17'd0 : pix_cnt;
    wire token_ok = (dout[DW+1] ? !in_frame : in_frame) && (dout[DW] == (index_now == PIXMAX - 1));
    always @(posedge cam_clk or negedge cam_ready) begin
        if (!cam_ready) begin
            rptr_bin <= 0;
            rptr_gry <= 0;
            wptr_gry_s1 <= 0;
            wptr_gry_s2 <= 0;
            overflow_c1 <= 0;
            overflow_c2 <= 0;
            fault_cam <= 0;
            div <= 0;
            pop_d <= 0;
            dout <= 0;
            in_frame <= 0;
            pix_cnt <= 0;
            idle_cnt <= 0;
            frame_cnt_q <= 0;
            cam_pixel <= 0;
            cam_valid <= 0;
            cam_frame_start <= 0;
            cam_frame_end <= 0;
        end else begin
            wptr_gry_s1 <= wptr_gry;
            wptr_gry_s2 <= wptr_gry_s1;
            overflow_c1 <= overflow_q || vin_peer_reset;
            overflow_c2 <= overflow_c1;
            cam_valid <= 0;
            cam_frame_start <= 0;
            cam_frame_end <= 0;
            div <= (div == PIX_DIV - 1) ? 8'd0 : div + 1'b1;
            pop_d <= pop;
            if (pop) begin
                dout <= mem[rptr_bin[FIFO_AW-1:0]];
                rptr_bin <= rptr_bin + 1'b1;
                rptr_gry <= bin2gry(rptr_bin + 1'b1);
            end
            if (overflow_c2 || cam_peer_reset) fault_cam <= 1;
            if (pop_d && !fault_cam && !overflow_c2 && !cam_peer_reset) begin
                idle_cnt <= 0;
                if (!token_ok) fault_cam <= 1;
                else begin
                    cam_pixel <= KEEP_RGB ? dout[DW-1:0] : {dout[7:0], dout[7:0], dout[7:0]};
                    cam_valid <= 1;
                    cam_frame_start <= dout[DW+1];
                    cam_frame_end <= dout[DW];
                    in_frame <= !dout[DW];
                    pix_cnt <= dout[DW] ? 17'd0 : index_now + 1'b1;
                    if (dout[DW]) frame_cnt_q <= frame_cnt_q + 1'b1;
                end
            end else if (in_frame && !fault_cam) begin
                if (idle_cnt < 24'hffffff) idle_cnt <= idle_cnt + 1'b1;
                if (idle_cnt >= IDLE_RST) fault_cam <= 1;
            end
        end
    end
    assign frame_cnt = frame_cnt_q;
    // synthesis translate_off
    initial begin
        if(H_DIV!=4||V_DIV<1||OUT_W<1||OUT_H<1||PIXMAX>131071||SOURCE_W>65535||SOURCE_H>65535||
     FIFO_AW<2||FIFO_AW>16||DROP_TH<1||DROP_TH>DEPTH||
     PIX_DIV<1||PIX_DIV>256||BLANK_TH<1||BLANK_TH>65534||IDLE_RST<1||IDLE_RST>16777214)
            $fatal(1, "Unsupported video_to_cam parameters");
    end
    // synthesis translate_on
endmodule
