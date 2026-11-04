// Queue target descriptors and periodic inspection requests.
module desc_packer #(
    parameter FRAME_W   = 320,
    parameter FRAME_H   = 240,
    parameter MAX_PIX   = 5461,
    parameter MAX_DIM   = 256,
    parameter FB_WIN_W  = 73,
    parameter FB_WIN_H  = 74,
    parameter MIN_WIN_W = 73,
    parameter MIN_WIN_H = 74,
    parameter ROI_PAD   = 2,
    parameter MAX_ROI   = 4,
    parameter PIXEL_FMT = 1,

    parameter TILE_COLS = 5,
    parameter TILE_ROWS = 4,

    parameter MIN_AREA = 60,
    parameter PRESERVE_CONTEXT = 0,
    parameter COMPACT_ROI = 1,
    parameter MOTION_FIRST = 0,
    parameter MOTION_BURST = 3
) (
    input wire clk,
    input wire rst_n,

    input wire [ 9:0] min_x,
    input wire [ 9:0] max_x,
    input wire [ 8:0] min_y,
    input wire [ 8:0] max_y,
    input wire [16:0] target_area,
    input wire [ 3:0] roi_id,
    input wire        bbox_valid,

    input wire force_inspect,

    input wire [16:0] frame_motion_count,

    input wire [31:0] frame_id,
    input wire [31:0] published_frame_id,

    input wire [31:0] cfg_session_id,

    input wire        drop_strobe,
    input wire [31:0] drop_frame_id,

    output reg          desc_valid,
    input  wire         desc_ready,
    output reg  [ 31:0] session_id,
    output reg  [ 31:0] request_id,
    output reg  [159:0] crop_meta,

    output reg [16:0] desc_motion_count,

    output reg has_motion,

    output reg [15:0] dropped,

    output wire [2:0] queued,

    output reg [15:0] noise_cnt,

    output wire [3:0] event_flags
);

    reg [31:0] req_counter;

    localparam [10:0] FRAME_W11   = FRAME_W;
    localparam [10:0] FRAME_H11   = FRAME_H;
    localparam [10:0] MAX_DIM11   = MAX_DIM;
    localparam [10:0] FB_WIN_W11  = FB_WIN_W;
    localparam [10:0] FB_WIN_H11  = FB_WIN_H;
    localparam [10:0] MIN_WIN_W11 = MIN_WIN_W;
    localparam [10:0] MIN_WIN_H11 = MIN_WIN_H;
    localparam [10:0] PAD11       = ROI_PAD;
    localparam [15:0] FRAME_W16   = FRAME_W;
    localparam [15:0] FRAME_H16   = FRAME_H;
    localparam [31:0] MAX_PIX32   = MAX_PIX;
    localparam [16:0] MIN_AREA17  = MIN_AREA;

    wire [10:0] min_w_eff = (FRAME_W < MIN_WIN_W) ? FRAME_W11 : MIN_WIN_W11;
    wire [10:0] min_h_eff = (FRAME_H < MIN_WIN_H) ? FRAME_H11 : MIN_WIN_H11;

    localparam QW = 108;
    reg [QW-1:0] fifo [0:MAX_ROI-1];
    reg [1:0]    wr_ptr;
    reg [1:0]    rd_ptr;
    reg [2:0]    cnt;
    assign queued = cnt;

    wire [90:0] q_item = fifo[rd_ptr][107:17];
    wire [16:0] q_motion = fifo[rd_ptr][16:0];
    wire [31:0] q_frame = q_item[90:59];
    wire [9:0] q_min_x = q_item[58:49];
    wire [9:0] q_max_x = q_item[48:39];
    wire [8:0] q_min_y = q_item[38:30];
    wire [8:0] q_max_y = q_item[29:21];
    wire [16:0] q_area = q_item[20:4];
    wire [3:0] q_roi = q_item[3:0];

    wire [10:0] ex0 = ({1'b0, q_min_x} > PAD11) ? ({1'b0, q_min_x} - PAD11) : 11'd0;
    wire [10:0] ey0 = ({2'b0, q_min_y} > PAD11) ? ({2'b0, q_min_y} - PAD11) : 11'd0;
    wire [10:0] ex1 = ({1'b0, q_max_x} + PAD11 < FRAME_W11) ? ({1'b0, q_max_x} + PAD11)
                                                             : FRAME_W11 - 11'd1;
    wire [10:0] ey1 = ({2'b0, q_max_y} + PAD11 < FRAME_H11) ? ({2'b0, q_max_y} + PAD11)
                                                             : FRAME_H11 - 11'd1;
    wire [10:0] exp_w = ex1 - ex0 + 11'd1;
    wire [10:0] exp_h = ey1 - ey0 + 11'd1;

    wire [10:0] need_w = (exp_w < min_w_eff) ? min_w_eff : exp_w;
    wire [10:0] need_h = (exp_h < min_h_eff) ? min_h_eff : exp_h;

    wire over_limit = (need_w > MAX_DIM11) || (need_h > MAX_DIM11) ||
                      (need_w > FRAME_W11) || (need_h > FRAME_H11) ||
                      ({12'b0, need_w} * {12'b0, need_h} > MAX_PIX32);

    wire [10:0] fb_w = (FRAME_W < FB_WIN_W) ? FRAME_W11 : FB_WIN_W11;
    wire [10:0] fb_h = (FRAME_H < FB_WIN_H) ? FRAME_H11 : FB_WIN_H11;

    wire [10:0] win_w = PRESERVE_CONTEXT ? need_w : over_limit ? fb_w : need_w;
    wire [10:0] win_h = PRESERVE_CONTEXT ? need_h : over_limit ? fb_h : need_h;

    wire [10:0] cx = ({1'b0, q_min_x} + {1'b0, q_max_x}) >> 1;
    wire [10:0] cy = ({2'b0, q_min_y} + {2'b0, q_max_y}) >> 1;
    wire [10:0] sx = {1'b0, q_min_x} + {1'b0, q_max_x} + 11'd1;
    wire [10:0] raw_x0 = PRESERVE_CONTEXT ? ((sx>=win_w)?((sx-win_w)>>1):0) : (cx >= (win_w >> 1)) ? (cx - (win_w >> 1)) : 11'd0;
    wire [10:0] sy = {2'b0, q_min_y} + {2'b0, q_max_y} + 11'd1;
    wire [10:0] raw_y0 = PRESERVE_CONTEXT ? ((sy>=win_h)?((sy-win_h)>>1):0) : (cy >= (win_h >> 1)) ? (cy - (win_h >> 1)) : 11'd0;
    wire [10:0] win_x0 = (raw_x0 + win_w > FRAME_W11) ? (FRAME_W11 - win_w) : raw_x0;
    wire [10:0] win_y0 = (raw_y0 + win_h > FRAME_H11) ? (FRAME_H11 - win_h) : raw_y0;

    localparam [10:0] TILE_W = FRAME_W / TILE_COLS;
    localparam [10:0] TILE_H = FRAME_H / TILE_ROWS;

    reg  [ 2:0] tile_col;
    reg  [ 1:0] tile_row;

    wire [10:0] tile_x0 = {8'd0, tile_col} * TILE_W;
    wire [10:0] tile_x1 = tile_col == TILE_COLS - 1 ? FRAME_W - 1 : tile_x0 + TILE_W - 11'd1;
    wire [10:0] tile_y0 = {9'd0, tile_row} * TILE_H;
    wire [10:0] tile_y1 = tile_row == TILE_ROWS - 1 ? FRAME_H - 1 : tile_y0 + TILE_H - 11'd1;

    wire [31:0] sess = (cfg_session_id == 32'd0) ? 32'd1 : cfg_session_id;

    reg  [31:0] last_drop_id;
    reg last_drop_valid, ids_exhausted;
    reg patrol_pending, patrol_queued, slot_forced;
    localparam MOTION_STREAK_W = (MOTION_BURST < 2) ? 1 : $clog2(MOTION_BURST + 1);
    reg [MOTION_STREAK_W-1:0] motion_streak;
    reg [31:0] accepted_frame;
    reg [2:0] accepted_in_frame;
    wire [2:0] accepted_now = (accepted_frame == frame_id) ? accepted_in_frame : 3'd0;

    wire motion_wanted = bbox_valid && (target_area >= MIN_AREA17) && (target_area != 0);

    wire motion_turn = MOTION_FIRST && motion_streak < MOTION_BURST;

    wire forced_wanted=(force_inspect||patrol_pending)&&!patrol_queued&&cnt==0&&!desc_valid&&
                       !motion_wanted;
    wire [31:0] entry_frame = forced_wanted ? published_frame_id : frame_id;
    wire incoming_dropped=(drop_strobe&&entry_frame==drop_frame_id)||
                         (last_drop_valid&&entry_frame==last_drop_id)||
                         (entry_frame<published_frame_id);
    wire head_invalid=(q_frame<published_frame_id)||
                      (drop_strobe&&q_frame==drop_frame_id)||
                      (last_drop_valid&&q_frame==last_drop_id);
    wire slot_invalid=(crop_meta[31:0]<published_frame_id)||
                      (drop_strobe&&crop_meta[31:0]==drop_frame_id)||
                      (last_drop_valid&&crop_meta[31:0]==last_drop_id);

    wire preempt_patrol=motion_turn&&(motion_wanted||(cnt!=0&&q_area!=0&&!head_invalid))&&
                       desc_valid&&slot_forced&&!desc_ready;
    wire slot_free = !desc_valid || desc_ready || slot_invalid || preempt_patrol;
    wire can_issue = slot_free && (cnt != 0) && !head_invalid && !ids_exhausted;
    wire pop_entry = (cnt != 0) && (head_invalid || can_issue);
    wire q_room = (cnt < MAX_ROI) || pop_entry;
    wire push_entry=(motion_wanted||forced_wanted)&&q_room&&!incoming_dropped&&
                    entry_frame!=0&&(forced_wanted||accepted_now<MAX_ROI)&&!ids_exhausted;
    assign event_flags = {
        motion_wanted && !incoming_dropped && (!push_entry || forced_wanted),
        ((cnt != 0 && head_invalid) || (desc_valid && slot_invalid)),
        motion_wanted && incoming_dropped,
        push_entry && !forced_wanted
    };

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            desc_valid <= 0;
            session_id <= 0;
            request_id <= 0;
            crop_meta <= 0;
            desc_motion_count <= 0;
            has_motion <= 0;
            req_counter <= 1;
            dropped <= 0;
            noise_cnt <= 0;
            wr_ptr <= 0;
            rd_ptr <= 0;
            cnt <= 0;
            tile_col <= 0;
            tile_row <= 0;
            last_drop_id <= 0;
            last_drop_valid <= 0;
            ids_exhausted <= 0;
            accepted_frame <= 0;
            accepted_in_frame <= 0;
            patrol_pending <= 0;
            patrol_queued <= 0;
            slot_forced <= 0;
            motion_streak <= 0;
        end else begin
            if (force_inspect) patrol_pending <= 1;
            if (preempt_patrol) patrol_queued <= 0;
            if (desc_valid && desc_ready && !slot_invalid) begin
                if (slot_forced) motion_streak <= 0;
                else if (motion_streak < MOTION_BURST) motion_streak <= motion_streak + 1'b1;
            end
            if((pop_entry&&head_invalid&&q_area==0)||(desc_valid&&slot_invalid&&slot_forced))
                patrol_queued <= 0;
            if (desc_valid && desc_ready && !slot_invalid && slot_forced) begin
                patrol_pending <= force_inspect;
                patrol_queued  <= 0;
                if (tile_col == TILE_COLS - 1) begin
                    tile_col <= 0;
                    tile_row <= (tile_row == TILE_ROWS - 1) ? 0 : tile_row + 1'b1;
                end else tile_col <= tile_col + 1'b1;
            end
            if (desc_valid && (desc_ready || slot_invalid || preempt_patrol)) desc_valid <= 0;
            if (drop_strobe) begin
                last_drop_id <= drop_frame_id;
                last_drop_valid <= 1;
            end
            if (accepted_frame != frame_id) begin
                accepted_frame <= frame_id;
                accepted_in_frame <= 0;
            end
            if (bbox_valid) has_motion <= target_area != 0;
            if (bbox_valid && target_area != 0 && target_area < MIN_AREA17) begin
                if (noise_cnt != 16'hffff) noise_cnt <= noise_cnt + 1'b1;
            end

            if((motion_wanted&&(!push_entry||forced_wanted))||
               (pop_entry&&head_invalid)||(desc_valid&&slot_invalid))begin
                if (dropped != 16'hffff) dropped <= dropped + 1'b1;
            end

            case ({
                push_entry, pop_entry
            })
                2'b10:   cnt <= cnt + 1'b1;
                2'b01:   cnt <= cnt - 1'b1;
                default: ;
            endcase
            if (push_entry) begin
                if (!forced_wanted)
                    fifo[wr_ptr] <= {
                        frame_id,
                        min_x,
                        max_x,
                        min_y,
                        max_y,
                        target_area,
                        (COMPACT_ROI ? {1'b0, accepted_now} : roi_id),
                        frame_motion_count
                    };
                else begin
                    fifo[wr_ptr] <= {
                        published_frame_id,
                        tile_x0[9:0],
                        tile_x1[9:0],
                        tile_y0[8:0],
                        tile_y1[8:0],
                        17'd0,
                        4'd0,
                        17'd0
                    };
                    patrol_queued <= 1;
                end
                wr_ptr <= (wr_ptr == MAX_ROI - 1) ? 0 : wr_ptr + 1'b1;
                if (!forced_wanted) begin
                    accepted_frame <= frame_id;
                    accepted_in_frame <= accepted_now + 1'b1;
                end
            end
            if (pop_entry) rd_ptr <= (rd_ptr == MAX_ROI - 1) ? 0 : rd_ptr + 1'b1;
            if (can_issue) begin
                slot_forced <= q_area == 0;
                desc_valid <= 1;
                session_id <= sess;
                request_id <= req_counter;
                desc_motion_count <= q_motion;
                if (req_counter == 32'hffffffff) ids_exhausted <= 1;
                else req_counter <= req_counter + 1'b1;
                crop_meta[31:0] <= q_frame;
                crop_meta[47:32] <= {12'd0, q_roi};
                crop_meta[63:48] <= FRAME_W16;
                crop_meta[79:64] <= FRAME_H16;
                crop_meta[95:80] <= {5'd0, win_x0};
                crop_meta[111:96] <= {5'd0, win_y0};
                crop_meta[127:112] <= {5'd0, win_w};
                crop_meta[143:128] <= {5'd0, win_h};
                crop_meta[151:144] <= PIXEL_FMT[7:0];
                crop_meta[159:152] <= 0;
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(MAX_ROI<1||MAX_ROI>4||MIN_AREA<1||MIN_AREA>131071||TILE_COLS<1||TILE_COLS>8||TILE_ROWS<1||TILE_ROWS>4||FRAME_W<TILE_COLS||FRAME_H<TILE_ROWS||MOTION_BURST<1||MOTION_BURST>16)
            $fatal(1, "Unsupported descriptor queue parameters");
    end
    // synthesis translate_on
endmodule
