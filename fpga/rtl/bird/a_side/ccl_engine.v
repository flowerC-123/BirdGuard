module ccl_engine #(
    parameter FRAME_W    = 320,
    parameter FRAME_H    = 240,
    parameter MAX_LABELS = 16,

    parameter MIN_RETAIN_AREA = 1,
    parameter ROOT_ITERS = 4
) (
    input wire clk,
    input wire rst_n,

    input wire motion_bit,
    input wire pixel_valid,
    input wire frame_start,

    output reg [ 9:0] out_min_x,
    output reg [ 9:0] out_max_x,
    output reg [ 8:0] out_min_y,
    output reg [ 8:0] out_max_y,
    output reg [16:0] out_area,
    output reg [ 3:0] out_index,
    output reg        out_valid,
    output reg [ 3:0] target_count,
    output reg        label_overflow,
    output reg        done
);

    reg [           9:0] target_min_x  [0:MAX_LABELS-1];
    reg [           9:0] target_max_x  [0:MAX_LABELS-1];
    reg [           8:0] target_min_y  [0:MAX_LABELS-1];
    reg [           8:0] target_max_y  [0:MAX_LABELS-1];
    reg [          16:0] target_area   [0:MAX_LABELS-1];

    reg [           9:0] x_cnt;
    reg [           8:0] y_cnt;
    reg                  in_frame;

    reg [           3:0] line_buf      [   0:FRAME_W-1];

    reg [           3:0] curr_label;
    reg                  curr_valid_d1;

    reg                  prev_valid;
    reg [           9:0] prev_px;

    reg [           3:0] label_map     [0:MAX_LABELS-1];
    reg [MAX_LABELS-1:0] free_labels;
    reg [3:0] reclaim_idx, high_used;
    reg [3:0] alloc_label;
    integer alloc_i;
    always @(*) begin
        alloc_label = 0;
        for (alloc_i = MAX_LABELS - 1; alloc_i >= 1; alloc_i = alloc_i - 1)
        if (free_labels[alloc_i]) alloc_label = alloc_i;
    end
    reg [ 3:0] next_label;

    reg [ 9:0] stat_min_x [0:MAX_LABELS-1];
    reg [ 9:0] stat_max_x [0:MAX_LABELS-1];
    reg [ 8:0] stat_min_y [0:MAX_LABELS-1];
    reg [ 8:0] stat_max_y [0:MAX_LABELS-1];
    reg [16:0] stat_area  [0:MAX_LABELS-1];
    reg        stat_valid [0:MAX_LABELS-1];

    localparam S_SCAN    = 2'd0;
    localparam S_RESOLVE = 2'd1;
    localparam S_OUTPUT  = 2'd2;
    reg  [1:0] state;

    reg  [3:0] resolve_idx;
    reg  [3:0] output_idx;
    reg  [3:0] emit_cnt;
    reg        frame_scanned;

    wire       cur_valid = stat_valid[output_idx] && (label_map[output_idx] == output_idx);

    wire [3:0] last_root = high_used;

    wire       eff_in_frame = in_frame | frame_start;
    wire [9:0] px = frame_start ? 10'd0 : x_cnt;
    wire [8:0] py = frame_start ? 9'd0 : y_cnt;

    wire [3:0] left_now = (px == 10'd0) ? 4'd0 : curr_label;

    wire [3:0] up_now = (py == 9'd0) ? 4'd0 : line_buf[px];

    function [3:0] find_root;
        input [3:0] label;
        integer i;
        reg [3:0] cur;
        begin
            cur = label;

            for (i = 0; i < ROOT_ITERS; i = i + 1) begin
                if (label_map[cur] == cur) cur = cur;
                else cur = label_map[cur];
            end
            find_root = cur;
        end
    endfunction

    wire last_pix = in_frame && pixel_valid && (x_cnt == FRAME_W - 1) && (y_cnt == FRAME_H - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_valid <= 0;
            prev_px <= 0;
        end else begin
            prev_valid <= pixel_valid && eff_in_frame;
            prev_px <= px;
            if (prev_valid && !frame_start) line_buf[prev_px] <= curr_label;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt         <= 10'd0;
            y_cnt         <= 9'd0;
            in_frame      <= 1'b0;
            curr_valid_d1 <= 1'b0;
        end else begin
            curr_valid_d1 <= pixel_valid && eff_in_frame;

            if (frame_start) begin
                x_cnt    <= pixel_valid ? 10'd1 : 10'd0;
                y_cnt    <= 9'd0;
                in_frame <= 1'b1;
            end else if (pixel_valid && in_frame) begin
                if (x_cnt == FRAME_W - 1) begin
                    x_cnt <= 10'd0;
                    if (y_cnt == FRAME_H - 1) in_frame <= 1'b0;
                    else y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    reg [3:0] new_label_a;
    reg [3:0] new_label_b;

    reg [9:0] mrg_min_x, mrg_max_x;
    reg [8:0] mrg_min_y, mrg_max_y;
    reg [16:0] mrg_area;

    always @(posedge clk or negedge rst_n) begin : ccl_fsm
        integer i;
        if (!rst_n) begin
            free_labels    <= {MAX_LABELS{1'b1}} & ~1;
            reclaim_idx    <= 1;
            high_used      <= 0;
            label_overflow <= 0;
            curr_label     <= 4'd0;
            next_label     <= 4'd1;
            state          <= S_SCAN;
            resolve_idx    <= 4'd0;
            output_idx     <= 4'd0;
            emit_cnt       <= 4'd0;
            done           <= 1'b0;
            target_count   <= 4'd0;
            frame_scanned  <= 1'b0;
            out_valid      <= 1'b0;
            out_min_x      <= 10'd0;
            out_max_x      <= 10'd0;
            out_min_y      <= 9'd0;
            out_max_y      <= 9'd0;
            out_area       <= 17'd0;
            out_index      <= 4'd0;

            for (i = 0; i < MAX_LABELS; i = i + 1) begin
                label_map[i]    <= i;
                stat_min_x[i]   <= 0;
                stat_max_x[i]   <= 0;
                stat_min_y[i]   <= 0;
                stat_max_y[i]   <= 0;
                stat_area[i]    <= 0;
                stat_valid[i]   <= 0;
                target_min_x[i] <= 0;
                target_max_x[i] <= 0;
                target_min_y[i] <= 0;
                target_max_y[i] <= 0;
                target_area[i]  <= 0;
            end
        end else begin
            done <= 1'b0;

            if (frame_start) begin
                free_labels    <= {MAX_LABELS{1'b1}} & ~1;
                reclaim_idx    <= 1;
                high_used      <= 0;
                label_overflow <= 0;
                out_valid      <= 0;
                curr_label     <= 0;
                state          <= S_SCAN;
                next_label     <= 4'd1;
                target_count   <= 4'd0;
                frame_scanned  <= 1'b0;
                for (i = 0; i < MAX_LABELS; i = i + 1) begin
                    label_map[i]  <= i;
                    stat_area[i]  <= 0;
                    stat_valid[i] <= 0;
                end

                if (pixel_valid && motion_bit) begin
                    free_labels[1] <= 0;
                    high_used <= 1;
                    curr_label <= 1;
                    stat_min_x[1] <= 0;
                    stat_max_x[1] <= 0;
                    stat_min_y[1] <= 0;
                    stat_max_y[1] <= 0;
                    stat_area[1] <= 1;
                    stat_valid[1] <= 1;
                end
            end else
                case (state)

                    S_SCAN: begin

                        out_valid <= 1'b0;

                        if (!pixel_valid && in_frame) begin
                            reclaim_idx <= (reclaim_idx == MAX_LABELS - 1) ? 1 : reclaim_idx + 1'b1;
                            if(stat_valid[reclaim_idx]&&label_map[reclaim_idx]==reclaim_idx&&
                           stat_area[reclaim_idx]<MIN_RETAIN_AREA&&
                           ({1'b0,stat_max_y[reclaim_idx]}+10'd1)<{1'b0,py})begin
                                for (i = 1; i < MAX_LABELS; i = i + 1) begin
                                    if (label_map[i] == reclaim_idx) begin
                                        free_labels[i] <= 1;
                                        label_map[i]   <= i;
                                        stat_valid[i]  <= 0;
                                        stat_area[i]   <= 0;
                                    end
                                end
                            end
                        end

                        if (last_pix) frame_scanned <= 1'b1;

                        if (pixel_valid && eff_in_frame) begin
                            if (motion_bit == 1'b0) begin

                                curr_label <= 4'd0;
                            end else begin

                                new_label_a = find_root(left_now);
                                new_label_b = find_root(up_now);

                                if (left_now == 4'd0 && up_now == 4'd0) begin

                                    if (alloc_label != 0) begin
                                        curr_label <= alloc_label;
                                        free_labels[alloc_label] <= 0;
                                        if (alloc_label > high_used) high_used <= alloc_label;
                                        stat_min_x[alloc_label] <= px;
                                        stat_max_x[alloc_label] <= px;
                                        stat_min_y[alloc_label] <= py;
                                        stat_max_y[alloc_label] <= py;
                                        stat_area[alloc_label]  <= 1;
                                        stat_valid[alloc_label] <= 1;
                                    end else begin
                                        curr_label <= 0;
                                        label_overflow <= 1;
                                    end
                                end else if (left_now != 4'd0 && up_now == 4'd0) begin

                                    curr_label <= new_label_a;
                                    if (px > stat_max_x[new_label_a]) stat_max_x[new_label_a] <= px;
                                    if (px < stat_min_x[new_label_a]) stat_min_x[new_label_a] <= px;
                                    if (py > stat_max_y[new_label_a]) stat_max_y[new_label_a] <= py;
                                    if (py < stat_min_y[new_label_a]) stat_min_y[new_label_a] <= py;
                                    stat_area[new_label_a] <= stat_area[new_label_a] + 1'b1;
                                end else if (left_now == 4'd0 && up_now != 4'd0) begin

                                    curr_label <= new_label_b;
                                    if (px > stat_max_x[new_label_b]) stat_max_x[new_label_b] <= px;
                                    if (px < stat_min_x[new_label_b]) stat_min_x[new_label_b] <= px;
                                    if (py > stat_max_y[new_label_b]) stat_max_y[new_label_b] <= py;
                                    if (py < stat_min_y[new_label_b]) stat_min_y[new_label_b] <= py;
                                    stat_area[new_label_b] <= stat_area[new_label_b] + 1'b1;
                                end else begin

                                    if (new_label_a == new_label_b) begin

                                        curr_label <= new_label_a;
                                        if (px > stat_max_x[new_label_a])
                                            stat_max_x[new_label_a] <= px;
                                        if (px < stat_min_x[new_label_a])
                                            stat_min_x[new_label_a] <= px;
                                        if (py > stat_max_y[new_label_a])
                                            stat_max_y[new_label_a] <= py;
                                        if (py < stat_min_y[new_label_a])
                                            stat_min_y[new_label_a] <= py;
                                        stat_area[new_label_a] <= stat_area[new_label_a] + 1'b1;
                                    end else begin

                                        if (new_label_a < new_label_b) begin
                                            label_map[new_label_b] <= new_label_a;

                                            for (i = 0; i < MAX_LABELS; i = i + 1)
                                            if (label_map[i] == new_label_b)
                                                label_map[i] <= new_label_a;
                                            curr_label <= new_label_a;

                                            mrg_min_x = stat_min_x[new_label_a];
                                            if (stat_min_x[new_label_b] < mrg_min_x)
                                                mrg_min_x = stat_min_x[new_label_b];
                                            if (px < mrg_min_x) mrg_min_x = px;
                                            mrg_max_x = stat_max_x[new_label_a];
                                            if (stat_max_x[new_label_b] > mrg_max_x)
                                                mrg_max_x = stat_max_x[new_label_b];
                                            if (px > mrg_max_x) mrg_max_x = px;
                                            mrg_min_y = stat_min_y[new_label_a];
                                            if (stat_min_y[new_label_b] < mrg_min_y)
                                                mrg_min_y = stat_min_y[new_label_b];
                                            if (py < mrg_min_y) mrg_min_y = py;
                                            mrg_max_y = stat_max_y[new_label_a];
                                            if (stat_max_y[new_label_b] > mrg_max_y)
                                                mrg_max_y = stat_max_y[new_label_b];
                                            if (py > mrg_max_y) mrg_max_y = py;
                                            mrg_area = stat_area[new_label_a] + stat_area[new_label_b] + 17'd1;

                                            stat_min_x[new_label_a] <= mrg_min_x;
                                            stat_max_x[new_label_a] <= mrg_max_x;
                                            stat_min_y[new_label_a] <= mrg_min_y;
                                            stat_max_y[new_label_a] <= mrg_max_y;
                                            stat_area[new_label_a]  <= mrg_area;
                                            stat_valid[new_label_b] <= 1'b0;
                                        end else begin
                                            label_map[new_label_a] <= new_label_b;

                                            for (i = 0; i < MAX_LABELS; i = i + 1)
                                            if (label_map[i] == new_label_a)
                                                label_map[i] <= new_label_b;
                                            curr_label <= new_label_b;
                                            mrg_min_x = stat_min_x[new_label_b];
                                            if (stat_min_x[new_label_a] < mrg_min_x)
                                                mrg_min_x = stat_min_x[new_label_a];
                                            if (px < mrg_min_x) mrg_min_x = px;
                                            mrg_max_x = stat_max_x[new_label_b];
                                            if (stat_max_x[new_label_a] > mrg_max_x)
                                                mrg_max_x = stat_max_x[new_label_a];
                                            if (px > mrg_max_x) mrg_max_x = px;
                                            mrg_min_y = stat_min_y[new_label_b];
                                            if (stat_min_y[new_label_a] < mrg_min_y)
                                                mrg_min_y = stat_min_y[new_label_a];
                                            if (py < mrg_min_y) mrg_min_y = py;
                                            mrg_max_y = stat_max_y[new_label_b];
                                            if (stat_max_y[new_label_a] > mrg_max_y)
                                                mrg_max_y = stat_max_y[new_label_a];
                                            if (py > mrg_max_y) mrg_max_y = py;
                                            mrg_area = stat_area[new_label_a] + stat_area[new_label_b] + 17'd1;

                                            stat_min_x[new_label_b] <= mrg_min_x;
                                            stat_max_x[new_label_b] <= mrg_max_x;
                                            stat_min_y[new_label_b] <= mrg_min_y;
                                            stat_max_y[new_label_b] <= mrg_max_y;
                                            stat_area[new_label_b]  <= mrg_area;
                                            stat_valid[new_label_a] <= 1'b0;
                                        end
                                    end
                                end
                            end
                        end

                        if (frame_scanned && !in_frame && !pixel_valid && !frame_start) begin
                            state         <= S_RESOLVE;
                            resolve_idx   <= 4'd0;
                            frame_scanned <= 1'b0;
                        end
                    end

                    S_RESOLVE: begin
                        state      <= S_OUTPUT;
                        output_idx <= 4'd0;
                        emit_cnt   <= 4'd0;
                    end

                    S_OUTPUT: begin
                        out_valid <= 1'b0;

                        if (cur_valid) begin
                            out_min_x <= stat_min_x[output_idx];
                            out_max_x <= stat_max_x[output_idx];
                            out_min_y <= stat_min_y[output_idx];
                            out_max_y <= stat_max_y[output_idx];
                            out_area  <= stat_area[output_idx];
                            out_index <= emit_cnt;
                            emit_cnt  <= emit_cnt + 4'd1;
                            out_valid <= 1'b1;
                        end

                        if ((output_idx < MAX_LABELS - 1) && (output_idx < last_root)) begin
                            output_idx <= output_idx + 1'b1;
                        end else begin
                            state <= S_SCAN;
                            done <= 1'b1;

                            target_count <= cur_valid ? (emit_cnt + 4'd1) : emit_cnt;
                        end
                    end

                endcase
        end
    end

    // synthesis translate_off
    initial begin
        if(FRAME_W<2||FRAME_W>1024||FRAME_H<1||FRAME_H>512||MAX_LABELS<2||MAX_LABELS>16||MIN_RETAIN_AREA<1)
            $fatal(1, "Unsupported CCL geometry/resources");
    end
    // synthesis translate_on
endmodule
