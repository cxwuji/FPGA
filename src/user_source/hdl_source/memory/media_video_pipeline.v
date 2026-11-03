`timescale 1ns/1ps

module media_video_pipeline #(
    parameter integer IMAGE_WORDS = 307200,
    parameter integer FIFO_DEPTH = 512,
    parameter integer FIFO_MARGIN = 16,
    parameter integer H_ACT = 640,
    parameter integer H_FP = 16,
    parameter integer H_SYNC = 96,
    parameter integer H_BP = 48,
    parameter integer V_ACT = 480,
    parameter integer V_FP = 10,
    parameter integer V_SYNC = 2,
    parameter integer V_BP = 33,
    parameter [31:0] DEFAULT_PERIOD_CYCLES = 32'd250000000,
    parameter [31:0] MIN_PERIOD_CYCLES = 32'd50000000,
    parameter [31:0] MAX_PERIOD_CYCLES = 32'd3000000000,
    // Non-zero enables the fade-out/black/fade-in transition on manual
    // switches and a fade-in on automatic slideshow switches. Zero keeps the
    // legacy direct-switch behaviour for the existing regression suites.
    parameter integer FADE_FRAMES = 0,
    parameter integer IMAGE_WIDTH = 640,    // R8-1a：缩略图 3x2，格子 = 宽/3 x 高/3
    parameter integer IMAGE_HEIGHT = 480
) (
    input  wire        ctrl_clk,
    input  wire        ctrl_rst_n,
    input  wire        next_event,
    input  wire        prev_event,          // 移植时加：上一张
    input  wire        preview_event,       // R8-2b：转场预览（同一张图消失再出现）
    input  wire        select_event,        // 第14课：缩略图确认（ctrl_clk 域）
    input  wire [2:0]  select_index,
    input  wire        thumb_view,          // 第14课：1 = 缩略图模式（ctrl_clk 域）
    input  wire [2:0]  thumb_focus,
    input  wire        toggle_auto_event,
    input  wire        no_transition,       // CPR 第 1 轮：1 = 急救中硬切（ctrl_clk 域电平）
    input  wire        emg_ovr_en,          // R7b-1 急救覆盖（ctrl_clk 域电平）：1 = 改读 emg_ovr_bank，播放器当前图不动
    input  wire [2:0]  emg_ovr_bank,
    input  wire        emg_ovr_black,       // 1 = 覆盖成黑底（急救图缺失 / 读取失败）
    input  wire [3:0]  fx_effect,           // R2：本次转场效果 / 速度（ctrl_clk 域，随请求锁存）
    input  wire [3:0]  fx_speed,
    input  wire [31:0] geo_stepx,           // R5：画面变换 DDA 参数（geom_param，ctrl_clk 域，慢变）
    input  wire [31:0] geo_startx,
    input  wire [31:0] geo_stepy,
    input  wire [31:0] geo_starty,
    input  wire        geo_mirror,
    input  wire        geo_flip,
    input  wire        period_cfg_valid,
    input  wire [31:0] period_cfg_cycles,
    input  wire        auto_cfg_valid,
    input  wire        auto_cfg_enabled,
    input  wire [4:0]  image_complete,
    input  wire        emg_ok,              // R8-1a：PIC6 已加载（缩略图第 6 格显示 / 黑）
    input  wire        player_enable,

    input  wire        mem_clk,
    input  wire        mem_rst_n,
    input  wire        controller_init_done,
    input  wire        controller_busy,
    input  wire        refresh_active,
    output wire        app_rd_en,
    output wire [20:0] app_rd_addr,
    input  wire        sdram_rd_valid,
    input  wire [31:0] sdram_rd_data,

    input  wire [7:0]  brightness,          // 第13课起：ctrl_clk 域（K3 菜单），下面同步并在帧边界锁存
    input  wire [7:0]  contrast,
    input  wire [1:0]  saturation,          // R8-2 显示页色彩档（ctrl_clk 域），和亮度 / 对比度一起同步、帧边界锁存
    input  wire        status_osd_en,       // R1：左上角状态 OSD 显示开关（ctrl_clk 域电平，慢变）
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    output wire        video_clk,
    output wire        video_hs,
    output wire        video_vs,
    output wire        video_de,
    output wire [23:0] video_rgb,
    output wire [9:0]  video_x,

    output wire [2:0]  active_index,
    output wire [2:0]  pending_index,
    output wire        request_busy,        // CPR 第 1 轮：切图请求未完成（ctrl_clk 域），cpr_flow_ctrl 空闲时才补发
    output wire        transition_busy,     // R2：转场进行中（ctrl_clk 域），自动轮播计时暂停
    output wire        auto_enabled,
    output wire        frame_start,
    output wire [7:0]  fade_alpha_out,      // 第11课：转场 alpha（音画同步淡入淡出用）
    output wire        fade_active_out,
    output wire        reader_busy,
    output wire        reader_underflow,
    output wire [7:0]  video_error
);
    wire raw_hs;
    wire raw_vs;
    wire raw_de;
    wire [11:0] raw_x;
    wire [11:0] raw_y;
    localparam integer H_BLANK = H_FP + H_SYNC + H_BP;
    wire [11:0] active_x = (raw_x >= H_BLANK) ? raw_x - H_BLANK : 12'd0;
    reg raw_vs_q;
    reg [9:0] video_x_q;
    wire index_commit;
    wire [7:0] control_error;
    wire [31:0] active_period_cycles;
    wire [23:0] reader_rgb;
    wire reader_pixel_valid;
    wire reader_done;
    wire [2:0] reader_index;
    wire [7:0] reader_error;
    wire player_enable_pix;
    wire [7:0] reader_error_pix;     // 错误码快照跨域后（像素域）
    wire [7:0] control_error_pix;
    // 第13课 2.5：亮度 / 对比度从 ctrl_clk 域 2FF 同步到像素域，连续两拍一致且在 frame_start 才锁存，一帧内不变
    reg [7:0] bri_s1, bri_s2, bri_pix;
    reg [7:0] con_s1, con_s2, con_pix;
    reg [1:0] sat_s1, sat_s2, sat_pix;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            bri_s1 <= 8'd255; bri_s2 <= 8'd255; bri_pix <= 8'd255;
            con_s1 <= 8'd128; con_s2 <= 8'd128; con_pix <= 8'd128;
            sat_s1 <= 2'd2;   sat_s2 <= 2'd2;   sat_pix <= 2'd2;
        end else begin
            bri_s1 <= brightness; bri_s2 <= bri_s1;
            con_s1 <= contrast;   con_s2 <= con_s1;
            sat_s1 <= saturation; sat_s2 <= sat_s1;
            if (frame_start && bri_s2 == bri_s1 && con_s2 == con_s1 && sat_s2 == sat_s1) begin
                bri_pix <= bri_s2;
                con_pix <= con_s2;
                sat_pix <= sat_s2;
            end
        end
    end

    // 第14课：缩略图模式 / 焦点 / 加载状态同步到像素域，view / focus 在 frame_start 锁存（整帧一致）
    reg       tv_s1, tv_s2, view_pix;
    reg [2:0] tf_s1, tf_s2, focus_pix;
    reg [5:0] ic_s1, ic_pix;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            tv_s1 <= 1'b0; tv_s2 <= 1'b0; view_pix <= 1'b0;
            tf_s1 <= 3'd0; tf_s2 <= 3'd0; focus_pix <= 3'd0;
            ic_s1 <= 6'd0; ic_pix <= 6'd0;
        end else begin
            tv_s1 <= thumb_view;  tv_s2 <= tv_s1;
            tf_s1 <= thumb_focus; tf_s2 <= tf_s1;
            ic_s1 <= {emg_ok, image_complete}; ic_pix <= ic_s1;
            if (frame_start) begin
                view_pix <= tv_s2;
                if (tf_s2 == tf_s1)
                    focus_pix <= tf_s2;
            end
        end
    end

    // R7b-1：急救覆盖同步到像素域，连续两拍一致且在 frame_start 才锁存（整帧一致，reader 在下一拍取走）
    reg  [4:0] ovr_s1, ovr_s2;
    reg        ovr_en_pix, ovr_black_pix;
    reg  [2:0] ovr_bank_pix;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            ovr_s1 <= 5'd0; ovr_s2 <= 5'd0;
            ovr_en_pix <= 1'b0; ovr_black_pix <= 1'b0; ovr_bank_pix <= 3'd0;
        end else begin
            ovr_s1 <= {emg_ovr_en, emg_ovr_black, emg_ovr_bank};
            ovr_s2 <= ovr_s1;
            if (frame_start && ovr_s2 == ovr_s1)
                {ovr_en_pix, ovr_black_pix, ovr_bank_pix} <= ovr_s2;
        end
    end
    wire view_eff = view_pix && !ovr_en_pix;   // 覆盖帧一律按全屏处理

    localparam integer V_BLANK = V_FP + V_SYNC + V_BP;
    wire [11:0] active_y = (raw_y >= V_BLANK) ? raw_y - V_BLANK : 12'd0;
    wire        thumb_de;
    wire        thumb_border, thumb_emg;
    // thumbnail_layout（R11 2x2：焦点黄边、未加载黑色，PIC6 不进缩略图）；缩小在 reader 的 mem 侧做（横向两点平均、纵向隔行）
    thumbnail_layout #(
        .DISPLAY_WIDTH  (H_ACT),
        .DISPLAY_HEIGHT (V_ACT)
    ) u_thumbnail_layout (
        .in_de          (raw_de),
        .pixel_x        (active_x),
        .pixel_y        (active_y),
        .focus_index    (focus_pix),
        .cell_valid     (ic_pix),
        .thumb_de       (thumb_de),
        .focus_border   (thumb_border),
        .emg_border     (thumb_emg)
    );

    // ---------------- R5 画面变换：行缓存 + 横向 DDA ----------------
    // reader 按输出行顺序给出源行（纵向缩放 / 翻转 / 平移在 reader 的行 DDA 里），比显示提前一行写进行缓存：
    //   第 L 行在扫描第 V_BLANK-1+L 行（上一行）时从 FIFO 取出写入，显示第 L 行时按 u = startx + x·stepx 从行缓存取（镜像 / 越界变黑）。
    // 参数在 frame_start 锁存（连续两拍一致才换，整帧不变）；缩略图帧强制恒等。
    localparam integer GP = 32 * 4 + 2;
    wire [GP-1:0] geo_a = {geo_stepx, geo_startx, geo_stepy, geo_starty, geo_mirror, geo_flip};
    reg  [GP-1:0] geo_s1, geo_s2;
    reg  [31:0]        gx_step, gy_step;
    reg  signed [31:0] gx_start, gy_start;
    reg                gx_mirror, gy_flip;
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            geo_s1 <= {GP{1'b0}}; geo_s2 <= {GP{1'b0}};
            gx_step <= 32'd65536; gx_start <= 32'sd0; gy_step <= 32'd65536; gy_start <= 32'sd0;
            gx_mirror <= 1'b0; gy_flip <= 1'b0;
        end else begin
            geo_s1 <= geo_a;  geo_s2 <= geo_s1;
            if (frame_start) begin
                if (tv_s2) begin
                    gx_step <= 32'd65536; gx_start <= 32'sd0; gy_step <= 32'd65536; gy_start <= 32'sd0;
                    gx_mirror <= 1'b0; gy_flip <= 1'b0;
                end else if (geo_s1 == geo_s2 && geo_s2[GP-1:GP-32] != 32'd0 && geo_s2[GP-65:GP-96] != 32'd0) begin
                    {gx_step, gx_start, gy_step, gy_start, gx_mirror, gy_flip} <= geo_s2;
                end
            end
        end
    end

    // 行缓存写：上一行取 FIFO
    wire        fill_de = (raw_x >= H_BLANK) && (raw_y >= V_BLANK - 1) && (raw_y < V_BLANK + V_ACT - 1);
    wire [11:0] fill_l  = raw_y - (V_BLANK - 1);
    reg  [24:0] lbuf [0:2047];
    always @(posedge pix_clk)
        if (fill_de)
            lbuf[{fill_l[0], active_x[9:0]}] <= {reader_pixel_valid, reader_rgb};

    // 横向 DDA：H_BLANK-1 起每拍给出下一像素的行缓存地址，读出正好对齐 raw_x = H_BLANK + k
    reg  signed [31:0] hacc;
    reg  signed [31:0] vacc;
    wire signed [15:0] hu = hacc[31:16];
    wire signed [15:0] vv = vacc[31:16];
    wire        hu_ok = (hu >= 0) && (hu < H_ACT);
    wire [9:0]  hu_x  = gx_mirror ? (H_ACT - 1 - hu[9:0]) : hu[9:0];
    wire        h_run = (raw_x >= H_BLANK - 1) && (raw_x < H_BLANK + H_ACT - 1);
    reg  [24:0] lb_q;
    reg         hx_ok, vy_ok;
    reg         raw_de_q;
    always @(posedge pix_clk) lb_q <= lbuf[{active_y[0], hu_x}];
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            hacc <= 32'sd0; vacc <= 32'sd0; hx_ok <= 1'b0; vy_ok <= 1'b1; raw_de_q <= 1'b0;
        end else begin
            raw_de_q <= raw_de;
            if (raw_x == H_BLANK - 2)
                hacc <= gx_start;
            else if (h_run)
                hacc <= hacc + $signed(gx_step);
            hx_ok <= hu_ok;
            // 纵向：每帧从 starty 开始，每个有效行结束加一次 stepy（与 reader 的行 DDA 同一套参数）
            if (raw_y == V_BLANK - 1 && raw_x == 12'd0)    // 帧开始后 gy_* 已锁存好
                vacc <= gy_start;
            else if (raw_de_q && !raw_de)
                vacc <= vacc + $signed(gy_step);
            vy_ok <= (vv >= 0) && (vv < V_ACT);
        end
    end
    wire [23:0] reader_sel_rgb =
        (player_enable_pix && lb_q[24] && hx_ok && vy_ok && reader_error_pix == 0 && !(ovr_en_pix && ovr_black_pix)) ?
        lb_q[23:0] : 24'h000000;
    // 缩略图模式：焦点格画黄边，PIC6（急救专用）画红边，未加载的格子 / 网格外黑色
    wire [23:0] selected_rgb = !view_eff ? reader_sel_rgb :
                               !thumb_de ? 24'h000000 :
                               thumb_border ? 24'hffd000 :
                               thumb_emg ? 24'he00000 : reader_sel_rgb;

    sync_2ff u_player_enable_pix (
        .clk(pix_clk), .rst_n(pix_rst_n), .async_in(player_enable),
        .sync_out(player_enable_pix)
    );

    // 移植（参考工程 sticky_error_cdc 思路）：错误码整组快照跨域，代替逐位 2FF，目的域不会看到半新半旧的拼凑码
    error_snapshot_cdc u_reader_error_cdc (
        .src_clk(mem_clk), .src_rst_n(mem_rst_n), .src_code(reader_error),
        .dst_clk(pix_clk), .dst_rst_n(pix_rst_n), .dst_code(reader_error_pix)
    );
    error_snapshot_cdc u_control_error_cdc (
        .src_clk(ctrl_clk), .src_rst_n(ctrl_rst_n), .src_code(control_error),
        .dst_clk(pix_clk), .dst_rst_n(pix_rst_n), .dst_code(control_error_pix)
    );

    video_timing_ctrl #(
        .H_ACT(H_ACT), .H_FP(H_FP), .H_SYNC(H_SYNC), .H_BP(H_BP),
        .V_ACT(V_ACT), .V_FP(V_FP), .V_SYNC(V_SYNC), .V_BP(V_BP),
        .ACTIVE_LAST(1)
    ) u_timing (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hsync(raw_hs),
        .vsync(raw_vs), .de(raw_de), .x(raw_x), .y(raw_y)
    );

    // R2 转场引擎：next / prev 请求先做"旧图按图形消失到黑"，全黑那一帧才放给 media_player_control，
    // 换图后再"新图按同一图形出现"。FADE_FRAMES=0 时直通（老回归逐像素不变），非 0 只作为使能。
    wire trans_next_event, trans_prev_event;
    wire       push_on, push_h;               // R12c 推移转场：转场引擎 -> reader
    wire [2:0] push_old;
    wire [9:0] push_off;
    wire [7:0] fade_alpha;
    wire [23:0] faded_rgb;
    transition_engine #(.ENABLE(FADE_FRAMES != 0), .H_ACT(H_ACT), .V_ACT(V_ACT)) u_trans (
        .ctrl_clk(ctrl_clk), .ctrl_rst_n(ctrl_rst_n),
        .next_in(next_event), .prev_in(prev_event), .preview_in(preview_event), .effect_in(fx_effect), .speed_in(fx_speed),
        .no_transition(no_transition),
        .next_out(trans_next_event), .prev_out(trans_prev_event), .busy(transition_busy),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .player_active(player_enable_pix), .frame_start(frame_start), .index_commit(index_commit),
        .de(raw_de), .x(active_x[9:0]), .y(active_y[9:0]), .bri(bri_pix),
        .rgb_in(selected_rgb), .rgb_out(faded_rgb),
        .audio_alpha(fade_alpha), .active(fade_active_out),
        .active_index(active_index), .push_on(push_on), .push_h(push_h), .push_old(push_old), .push_off(push_off)
    );

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            raw_vs_q <= 1'b1;
        else
            raw_vs_q <= raw_vs;
    end
    assign frame_start = raw_vs_q && !raw_vs;
    assign fade_alpha_out = fade_alpha;

    // rgb_video_adapter registers hs/vs/de/rgb by one pixel. Register x in
    // parallel so the HDMI Data Island scheduler sees the coordinate belonging
    // to the same output character, rather than the next raw VTC position.
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n)
            video_x_q <= 10'd0;
        else
            video_x_q <= active_x[9:0];
    end
    assign video_x = video_x_q;

    media_player_control #(
        .DEFAULT_PERIOD_CYCLES(DEFAULT_PERIOD_CYCLES),
        .MIN_PERIOD_CYCLES(MIN_PERIOD_CYCLES),
        .MAX_PERIOD_CYCLES(MAX_PERIOD_CYCLES)
    ) u_control (
        .sys_clk(ctrl_clk), .sys_rst_n(ctrl_rst_n),
        // 急救中丢弃转场模块延后放出的"下一张"（淡出途中拨 SW4 时），切图只听 cpr_flow_ctrl 的 select
        .next_event(trans_next_event & ~no_transition), .prev_event(trans_prev_event & ~no_transition),
        .select_event(select_event), .select_index(select_index),
        .toggle_auto_event(toggle_auto_event),
        .period_cfg_valid(period_cfg_valid),
        .period_cfg_cycles(period_cfg_cycles),
        .auto_cfg_valid(auto_cfg_valid),
        .auto_cfg_enabled(auto_cfg_enabled),
        .image_complete(image_complete), .auto_enabled(auto_enabled),
        .active_period_cycles(active_period_cycles),
        .pending_index(pending_index), .control_error(control_error),
        .request_busy(request_busy), .pix_clk(pix_clk),
        .pix_rst_n(pix_rst_n), .frame_start(frame_start),
        .active_index(active_index), .index_commit(index_commit)
    );

    media_frame_reader #(
        .ADDR_WIDTH(21), .IMAGE_WORDS(IMAGE_WORDS),
        .FIFO_DEPTH(FIFO_DEPTH), .FIFO_MARGIN(FIFO_MARGIN),
        .MAX_INFLIGHT_BURSTS(2), .DIAG_RETURN_PATTERN(0),
        .DIAG_SYNTH_STREAM(0),
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT)
    ) u_reader (
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done && player_enable),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_rd_en(app_rd_en), .app_rd_addr(app_rd_addr),
        .sdram_rd_valid(sdram_rd_valid), .sdram_rd_data(sdram_rd_data),
        .pix_clk(pix_clk), .pix_rst_n(pix_rst_n),
        .frame_start(frame_start && player_enable_pix), .active_index(active_index),
        .ovr_en(ovr_en_pix), .ovr_bank(ovr_bank_pix),
        .thumb_mode(view_pix),
        .geo_stepy(gy_step), .geo_starty(gy_start), .geo_flip(gy_flip),
        .push_on(push_on), .push_h(push_h), .push_old(push_old), .push_off(push_off),
        .pixel_consume(fill_de && player_enable_pix), .pixel_rgb(reader_rgb),
        .pixel_valid(reader_pixel_valid), .underflow(reader_underflow),
        .reader_busy(reader_busy), .frame_read_done(reader_done),
        .reader_index(reader_index), .reader_error(reader_error)
    );

    // 第9课 OSD 状态叠加（文档 4.2：转场之后、rgb_video_adapter 之前）。
    // 左上角 (8,8) 显示 4 个字符：图片编号 1~4 / A 自动、E 手动 / 错误码两位（无错黄色，有错红色）
    // 第13课：对比度（文档 4.2，转场之后、OSD 之前）。模块输出打了一拍，后面的时序信号同样延后一拍
    // R8-2b 时序：转场输出先寄存一拍再进亮度对比度（y 计数 -> 缩略图比较 -> 转场遮罩 -> 对比度乘法原来是一整段 40ns 组合路径）
    wire [23:0] bc_rgb;
    reg  [23:0] faded_q;
    always @(posedge pix_clk) faded_q <= faded_rgb;
    brightness_contrast_adjust u_brightness_contrast (
        .clk        (pix_clk),
        .rst_n      (pix_rst_n),
        .in_de      (raw_de),
        .rgb_in     (faded_q),
        .brightness (8'd255),           // 亮度已按完赛做法折进转场 alpha（文档 2.1）
        .contrast   (con_pix),
        .saturation (sat_pix),
        .out_de     (),
        .rgb_out    (bc_rgb)
    );
    // faded_q 1 拍 + brightness_contrast_adjust 3 拍（R8-2 加了色彩 2 拍），同步信号跟着延迟 4 拍
    reg  [3:0] hs_dl, vs_dl, de_dl;
    wire       raw_hs_d = hs_dl[3], raw_vs_d = vs_dl[3], raw_de_d = de_dl[3];
    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            hs_dl <= 4'b1111; vs_dl <= 4'b1111; de_dl <= 4'b0000;
        end else begin
            hs_dl <= {hs_dl[2:0], raw_hs}; vs_dl <= {vs_dl[2:0], raw_vs}; de_dl <= {de_dl[2:0], raw_de};
        end
    end

    // R8-0a：旧 ASCII 状态 OSD（osd_overlay_24，R1.5b 起开关恒为 0）删除，status_osd_en 端口保留不用
    wire [23:0] osd_rgb_out = bc_rgb;

    // R12d：DE 不再等 player_enable（原来第 13 课起图片读完前 DE 恒 0，HDMI 没有有效视频期，开机读图黄框 / 没卡故障条画不出来）；
    //   读完前像素由 reader_sel_rgb 的 player_enable_pix 条件压成黑色
    rgb_video_adapter u_video_adapter (
        .pclk(pix_clk), .rst_n(pix_rst_n), .hs_in(raw_hs_d),
        .vs_in(raw_vs_d), .de_in(raw_de_d),
        .rgb_in(osd_rgb_out), .video_clk(video_clk),
        .video_hs(video_hs), .video_vs(video_vs),
        .video_de(video_de), .video_rgb(video_rgb)
    );

    assign video_error = reader_error_pix != 0 ? reader_error_pix :
                         reader_underflow ? 8'h63 : control_error_pix;
endmodule
