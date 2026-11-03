`timescale 1ns/1ps
`include "../user_source/hdl_source/include/ui_text.vh"
`define TEXT_ROM_HEX "src/user_source/hdl_source/io/text_rom.hex"
// 第8课 四 bank 帧缓存自检：按顶层的接法把真实模块连起来——
//   sd_card_bmp（FAT32 + bmp_read + 上电加载流程）-> media_frame_loader -> media_sdram_write_cdc -> SDRAM 模型
//   SDRAM 模型 -> media_video_pipeline（timing + player_control + frame_reader + rgb_adapter）-> 逐像素检查
// SD 卡和 SDRAM 控制器、rfifo_32_32_512 用行为模型。图片 64x48，显示时序缩小为 80x56（H 4/8/4，V 2/2/4）。
// 每张图每个像素都不同：B = {图号, BMP 文件内行号}，G = 列号，R = 0xA0 + 图号；
// 显示第 y 行必须是 BMP 文件的第 47-y 行（检查上下翻转），每一帧必须整帧属于同一张图（检查不撕裂）。
// 宏：-DTOPDOWN（R8-5b）PIC2 存成负高度 BMP（自上而下），期望显示不变。-DMISSING3 删掉 PIC3（只有 3 张轮播：bank0~2 = PIC1/2/4）。-DMISSING6 删掉 PIC6（急救图，急救时黑底）。
// R8-1a：PIC6 急救图（bank5，R = 0xA6），急救全程画面覆盖成 PIC6，退出回到原来那张。
// R11：轮播只用 PIC1~4（bank0~3；卡上的 PIC5 不认、不加载）；缩略图 2x2（每格 W/2 x H/2，横向两点平均、纵向隔行，PIC6 不进缩略图，焦点 0~3）。
// 运行（仓库根目录）：见 sim/run_fourbank.sh

module tb_fourbank;

localparam integer CPMS = 100;            // sd_card_clk 100 个时钟 = 1ms（CLK_FREQ_HZ = 100_000）
localparam integer W = 64, H = 48;
localparam integer WORDS = W * H;

reg sd_clk = 1'b0;  always #5 sd_clk  = ~sd_clk;    // sd_card_clk 100MHz
reg mem_clk = 1'b0; always #4 mem_clk = ~mem_clk;   // ext_mem_clk 125MHz
reg pix_clk = 1'b0; always #20 pix_clk = ~pix_clk;  // video_clk 25MHz
reg rst_n = 1'b0;
reg key_next = 1'b1;
reg key_auto = 1'b1;
reg key3 = 1'b1;
reg sw1 = 1'b0;          // 拨码：1 = 开（ui_key_router SW_ON_LEVEL=1）
reg sw4 = 1'b1;          // SW4 = 背景音乐（R7a 起急救入口是 K4 单击）；开着，M7 检查音量增益
reg key0 = 1'b1;         // K1：自动轮播
`ifdef NOCARD
reg card_in = 1'b0;      // R4：上电没插卡
`else
reg card_in = 1'b1;
`endif
reg sw2 = 1'b0;          // R1 功能页：{SW3,SW2}
reg sw3 = 1'b0;

wire sdcard_rst_n, mem_rst_n, video_rst_n;
reset_sync u_rs_sd  (.clk(sd_clk),  .ext_rst_n(rst_n), .rst_n_sync(sdcard_rst_n));
reset_sync u_rs_mem (.clk(mem_clk), .ext_rst_n(rst_n), .rst_n_sync(mem_rst_n));
reset_sync u_rs_pix (.clk(pix_clk), .ext_rst_n(rst_n), .rst_n_sync(video_rst_n));

// ---------------- SDRAM 控制器模型 ----------------
reg  [31:0] sdram [0:6*WORDS-1];
reg         Sdr_init_done = 1'b0;
wire        App_wr_en, App_rd_en;
wire [20:0] App_wr_addr, App_rd_addr;
wire [3:0]  App_wr_dm;
wire [31:0] App_wr_din;
reg  [7:0]  rd_pipe_v = 0;
reg  [31:0] rd_pipe_d [0:7];
wire        Sdr_rd_en   = rd_pipe_v[7];
wire [31:0] Sdr_rd_dout = rd_pipe_d[7];
integer     n_wr = 0, n_wr_overlap = 0;
integer     ri;
initial begin #2000; @(posedge mem_clk) Sdr_init_done = 1'b1; end
always @(posedge mem_clk) begin
    if (App_wr_en) begin
        sdram[App_wr_addr] <= App_wr_din;
        n_wr = n_wr + 1;
        if (App_rd_en || rd_pipe_v != 0) n_wr_overlap = n_wr_overlap + 1;
    end
    rd_pipe_v <= {rd_pipe_v[6:0], App_rd_en};
    rd_pipe_d[0] <= sdram[App_rd_addr];
    for (ri = 1; ri < 8; ri = ri + 1) rd_pipe_d[ri] <= rd_pipe_d[ri-1];
end

// 刷新准入模型（对应 SD/sdram.v 的 sdram_refresh_admission + sdr_init_ref 的刷新时刻）。
// 为了加压，周期取 600 拍（真实 3906 拍），守护窗口与真实相同：刷新前 192 拍、刷新后 32 拍不准开始新突发。
// 刷新在槽内第 period-10 拍开始、持续 20 拍；期间出现任何 App_wr_en / App_rd_en 都记为违例。
localparam integer TB_REF_PERIOD = 600;
reg  [13:0] ref_slot = 0;
reg  [4:0]  ref_left = 0;
wire        Sdr_refresh = (ref_left != 0);
wire        Sdr_busy = !Sdr_init_done || ref_slot >= TB_REF_PERIOD - 192 || ref_slot < 32;
integer     n_rw_in_refresh = 0;
always @(posedge mem_clk) begin
    if (!Sdr_init_done) ref_slot <= 0;
    else ref_slot <= (ref_slot == TB_REF_PERIOD - 1) ? 14'd0 : ref_slot + 1'b1;
    if (Sdr_init_done && ref_slot == TB_REF_PERIOD - 10) ref_left <= 5'd20;
    else if (ref_left != 0) ref_left <= ref_left - 1'b1;
    if (Sdr_refresh && (App_wr_en || App_rd_en)) n_rw_in_refresh = n_rw_in_refresh + 1;
end

wire Sdr_init_done_sd;
sync_2ff u_sdi (.clk(sd_clk), .rst_n(sdcard_rst_n), .async_in(Sdr_init_done), .sync_out(Sdr_init_done_sd));

// ---------------- 与顶层相同的连接 ----------------
wire        display_valid;
wire [3:0]  state_code;
wire        loading;
wire [11:0] last_load_time;
wire        last_load_err;
wire [7:0]  fs_error;
wire [2:0]  img_found_count;
wire        thumb_view;
wire [2:0]  thumb_focus;
wire        loader_load_start, loader_pixel_valid, loader_frame_commit, loader_load_busy, loader_load_done;
wire [2:0]  loader_image_index;
wire [23:0] loader_pixel_rgb;
wire        loader_pixel_ready;
wire        loader_top_down;
wire [7:0]  loader_decode_error, loader_memory_error;
wire [4:0]  loader_image_complete;
wire        loader_app_wr_en;
wire [20:0] loader_app_wr_addr;
wire [3:0]  loader_app_wr_mask;
wire [31:0] loader_app_wr_data;
wire        cdc_clear, cdc_idle_mem, cdc_idle_sd, cdc_src_rst_n, cdc_dst_rst_n, cdc_overflow;
wire [2:0]  active_index;
wire        auto_enabled, reader_underflow;
wire [7:0]  video_error;
wire        player_enable_mem;
wire        sd_ncs, sd_dclk, sd_mosi;
wire        bc_freeze;
wire [7:0]  menu_brightness, menu_contrast, pipe_brightness, pipe_contrast;
wire [1:0]  pipe_sat;
wire        thumb_key_right, thumb_key_left, thumb_key_confirm, thumb_key_mode;
wire        pipe_next_event, pipe_prev_event, pipe_select_event;
wire [2:0]  pipe_select_index, pipe_pending_index;
wire        pipe_auto_cfg_valid, pipe_auto_cfg_enabled, pipe_no_transition, pipe_request_busy;
wire        pipe_transition_busy, auto_run;
wire [3:0]  pipe_fx_effect, pipe_fx_speed;
wire [31:0] geo_stepx, geo_startx, geo_stepy, geo_starty;
wire        geo_mirror, geo_flip;
wire        cpr_active, cpr_mode_302;
wire [2:0]  cpr_state;
wire [15:0] cpr_timer_bcd, cpr_aed_time_bcd;
wire        cpr_breath, cpr_beat, key_tick;
wire [1:0]  ui_page;
wire        menu_visible, status_osd_en;
wire        hint_show, hint_leave;
wire [7:0]  menu_vol_gain;

wire        tf_sd_ready, tf_boot_done, tf_lost, tf_recovered, music_found;
wire [5:0]  tf_found_mask, tf_giveup_mask;
wire [3:0]  fault_code;
wire        emg_ok, emg_ovr_en, emg_ovr_black;
wire [2:0]  emg_ovr_bank;
wire [2:0]  fault_arg, fault_tot;
wire        fault_show;
tf_fault_monitor #(.CLKS_PER_MS(100)) u_fault (
    .clk(sd_clk), .rst_n(sdcard_rst_n), .display_valid(display_valid), .sd_ready(tf_sd_ready), .boot_done(tf_boot_done),
    .fs_error(fs_error), .found_mask(tf_found_mask), .giveup_mask(tf_giveup_mask), .tf_lost(tf_lost),
    .music_found(music_found), .music_on(1'b0), .crc_fail_cnt(8'd0), .load_idx(loader_image_index), .suppress(cpr_active),
    .code(fault_code), .arg(fault_arg), .tot(fault_tot)
);
wire         save_ld;            // R8-4a
wire [199:0] save_dat;
wire         save_req, save_fail;  // R8-4b
wire [255:0] save_img;
sd_card_bmp #(
    .CLK_FREQ_HZ     (100_000),
    .LONG_PRESS_MS   (1000),
    .LOAD_TIMEOUT_MS (1000),
    .OUT_W           (W),
    .OUT_H           (H)
) dut (
    .clk(sd_clk), .rst(~sdcard_rst_n), .sdram_init_done(Sdr_init_done_sd),
    .bmp_width(W[15:0]), .bmp_height(H[15:0]),
    .display_valid(display_valid), .state_code(state_code), .loading(loading),
    .last_load_time(last_load_time), .last_load_err(last_load_err),
    .abort_code(), .abort_sd_stage(), .crc_err_cnt(), .rd_retry_cnt(), .crc_fail_cnt(), .fs_error(fs_error),
    .img_found_count(img_found_count),
    .loader_load_start(loader_load_start), .loader_image_index(loader_image_index),
    .loader_pixel_valid(loader_pixel_valid), .loader_pixel_rgb(loader_pixel_rgb), .loader_pixel_ready(loader_pixel_ready), .loader_top_down(loader_top_down),
    .loader_frame_commit(loader_frame_commit), .loader_decode_error(loader_decode_error),
    .loader_load_done(loader_load_done), .loader_memory_error(loader_memory_error),
    .cdc_clear(cdc_clear), .cdc_idle(cdc_idle_sd),
    .sd_ready(tf_sd_ready), .boot_done(tf_boot_done), .found_mask(tf_found_mask), .giveup_mask(tf_giveup_mask), .emg_ok(emg_ok),
    .tf_lost(tf_lost), .tf_recovered(tf_recovered),
    .music_found(music_found), .music_start_lba(), .music_sectors(), .save_ld(save_ld), .save_dat(save_dat), .save_req(save_req), .save_img(save_img), .save_fail(save_fail), .wav_sd_enable(),
    .guide_found(), .guide_lba(), .u_loc_we(1'b0), .u_loc_addr(10'd0), .u_loc_data(8'd0), .u_loc_ev(1'b0), .loc_we(), .loc_addr(), .loc_data(), .loc_ra(), .loc_q(8'd0),
    .wav_sector_req(1'b0), .wav_sector_lba(32'd0), .wav_sector_busy(), .wav_sector_valid(), .wav_sector_byte(),
    .wav_sector_byte_index(), .wav_sector_done(), .wav_sector_error(),
    .SD_nCS(sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(1'b1)
);

media_frame_loader #(
    .ADDR_WIDTH(21), .IMAGE_WORDS(WORDS), .FIFO_DEPTH(512), .BURST_SIZE(128), .STALL_TIMEOUT(65535),
    .V_FLIP(1), .IMAGE_WIDTH(W), .IMAGE_HEIGHT(H)
) u_loader (
    .clk(sd_clk), .rst_n(sdcard_rst_n),
    .load_start(loader_load_start), .image_index(loader_image_index),
    .pixel_valid(loader_pixel_valid), .pixel_rgb(loader_pixel_rgb), .pixel_ready(loader_pixel_ready), .top_down(loader_top_down),
    .frame_commit(loader_frame_commit), .decode_error(loader_decode_error),
    .load_busy(loader_load_busy), .load_done(loader_load_done),
    .image_complete(loader_image_complete), .memory_error(loader_memory_error),
    .controller_init_done(Sdr_init_done_sd), .controller_busy(1'b0), .refresh_active(1'b0),
    .app_wr_en(loader_app_wr_en), .app_wr_addr(loader_app_wr_addr),
    .app_wr_mask(loader_app_wr_mask), .app_wr_data(loader_app_wr_data)
);

reset_sync u_cdc_src_reset (.clk(sd_clk),  .ext_rst_n(sdcard_rst_n & ~cdc_clear), .rst_n_sync(cdc_src_rst_n));
reset_sync u_cdc_dst_reset (.clk(mem_clk), .ext_rst_n(mem_rst_n & ~cdc_clear),    .rst_n_sync(cdc_dst_rst_n));

media_sdram_write_cdc #(.ADDR_WIDTH(21), .FIFO_ADDR_WIDTH(9), .BURST_SIZE(128)) u_cdc (
    .src_clk(sd_clk), .src_rst_n(cdc_src_rst_n),
    .src_wr_en(loader_app_wr_en), .src_wr_addr(loader_app_wr_addr),
    .src_wr_mask(loader_app_wr_mask), .src_wr_data(loader_app_wr_data),
    .src_full(), .src_overflow(cdc_overflow),
    .dst_clk(mem_clk), .dst_rst_n(cdc_dst_rst_n),
    .dst_app_wr_en(App_wr_en), .dst_app_wr_addr(App_wr_addr),
    .dst_app_wr_mask(App_wr_dm), .dst_app_wr_data(App_wr_din), .dst_idle(cdc_idle_mem),
    .dst_burst_allowed(!Sdr_busy && !Sdr_refresh)
);

sync_2ff u_cdc_idle_sync (.clk(sd_clk), .rst_n(sdcard_rst_n), .async_in(cdc_idle_mem), .sync_out(cdc_idle_sd));
sync_2ff u_pe_sync (.clk(mem_clk), .rst_n(mem_rst_n), .async_in(display_valid), .sync_out(player_enable_mem));

wire        v_hs, v_vs, v_de;
wire [23:0] v_rgb;
media_video_pipeline #(
    .IMAGE_WORDS(WORDS), .FIFO_DEPTH(512), .FIFO_MARGIN(16),
    .H_ACT(W), .H_FP(4), .H_SYNC(8), .H_BP(4),
    .V_ACT(H), .V_FP(2), .V_SYNC(2), .V_BP(4),
    .DEFAULT_PERIOD_CYCLES(32'd300_000), .MIN_PERIOD_CYCLES(32'd100_000), .MAX_PERIOD_CYCLES(32'd3_000_000),
`ifdef FADE16
    .FADE_FRAMES(16),
`else
    .FADE_FRAMES(0),
`endif
    .IMAGE_WIDTH(W), .IMAGE_HEIGHT(H)
) u_pipe (
    .ctrl_clk(sd_clk), .ctrl_rst_n(sdcard_rst_n),
    .next_event(pipe_next_event), .prev_event(pipe_prev_event), .preview_event(pipe_preview_event),
    .toggle_auto_event(1'b0), .no_transition(pipe_no_transition),
    .emg_ovr_en(emg_ovr_en), .emg_ovr_bank(emg_ovr_bank), .emg_ovr_black(emg_ovr_black), .fx_effect(pipe_fx_effect), .fx_speed(pipe_fx_speed),
    .geo_stepx(geo_stepx), .geo_startx(geo_startx), .geo_stepy(geo_stepy), .geo_starty(geo_starty),
    .geo_mirror(geo_mirror), .geo_flip(geo_flip),
    .select_event(pipe_select_event),
    .select_index(pipe_select_index), .thumb_view(thumb_view), .thumb_focus(thumb_focus),
    .period_cfg_valid(1'b0), .period_cfg_cycles(32'd0),
    .auto_cfg_valid(pipe_auto_cfg_valid), .auto_cfg_enabled(pipe_auto_cfg_enabled),
    .image_complete(loader_image_complete), .emg_ok(emg_ok), .player_enable(player_enable_mem),
    .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
    .controller_init_done(Sdr_init_done), .controller_busy(Sdr_busy), .refresh_active(Sdr_refresh),
    .app_rd_en(App_rd_en), .app_rd_addr(App_rd_addr),
    .sdram_rd_valid(Sdr_rd_en), .sdram_rd_data(Sdr_rd_dout),
    .brightness(pipe_brightness), .contrast(pipe_contrast), .saturation(pipe_sat), .status_osd_en(status_osd_en), .pix_clk(pix_clk), .pix_rst_n(video_rst_n),
    .video_clk(), .video_hs(v_hs), .video_vs(v_vs), .video_de(v_de), .video_rgb(v_rgb), .video_x(),
    .active_index(active_index), .pending_index(pipe_pending_index), .request_busy(pipe_request_busy), .transition_busy(pipe_transition_busy), .auto_enabled(auto_enabled), .frame_start(),
    .reader_busy(), .reader_underflow(reader_underflow), .video_error(video_error)
);

// ---------------- 第14课：与顶层相同的 K3 菜单 + 缩略图控制器 ----------------
reg fs_tgl_pix = 1'b0;
reg [2:0] fs_tgl_sd = 3'b000;
always @(posedge pix_clk) if (u_pipe.frame_start) fs_tgl_pix <= ~fs_tgl_pix;
always @(posedge sd_clk) fs_tgl_sd <= {fs_tgl_sd[1:0], fs_tgl_pix};
thumbnail_controller u_thumb (
    .clk(sd_clk), .rst_n(sdcard_rst_n),
    .key_right(thumb_key_right), .key_left(thumb_key_left),
    .key_confirm(thumb_key_confirm), .key_mode(thumb_key_mode),
    .image_complete(loader_image_complete), .frame_start(fs_tgl_sd[2] ^ fs_tgl_sd[1]),
    .view_mode(thumb_view), .focus_index(thumb_focus), .active_index(), .transition_req()
);

// ---------------- CPR 按键改版：与顶层相同的 ui_key_router ----------------
ui_key_router #(.CLKS_PER_MS(CPMS), .SW_ON_LEVEL(1'b1), .IMG_W(W), .IMG_H(H)) u_router (
    .clk(sd_clk), .rst_n(sdcard_rst_n), .display_valid(display_valid),
    .img_found_count(img_found_count), .image_complete(loader_image_complete), .emg_ok(emg_ok),
    .k1_n(key0), .k2_n(key_next), .k3_n(key3), .k4_n(key_auto),
    .sw1_in(sw1), .sw2_in(sw2), .sw3_in(sw3), .sw4_in(sw4),
    .thumb_view(thumb_view), .thumb_focus(thumb_focus),
    .pending_index(pipe_pending_index), .request_busy(pipe_request_busy), .transition_busy(pipe_transition_busy), .auto_enabled(auto_enabled), .cur_index(active_index),
    .fault_code(fault_code), .fault_arg(fault_arg), .fault_tot(fault_tot), .tfok_hint(tf_recovered), .fault_show(fault_show),
    .sub_upd(1'b0), .sub_rst(1'b0), .sub_show(1'b0), .sub_mot(2'd0), .save_ld(save_ld), .save_dat(save_dat), .save_req(save_req), .save_img(save_img), .save_fail(save_fail),
    .guide_ok(1'b0), .g_own(), .g_play(), .g_seg(), .cpr_beep(), .cpr_part(),     // R9：本 tb 没有 GUIDE.WAV（语音见 tb_guide）
    .menu_brightness(menu_brightness), .menu_contrast(menu_contrast),
    .menu_sat(), .sub_color(), .auto_int(), .pipe_sat(pipe_sat),
    .pipe_next_event(pipe_next_event), .pipe_prev_event(pipe_prev_event), .pipe_preview_event(pipe_preview_event),
    .pipe_select_event(pipe_select_event), .pipe_select_index(pipe_select_index),
    .pipe_auto_cfg_valid(pipe_auto_cfg_valid), .pipe_auto_cfg_enabled(pipe_auto_cfg_enabled),
    .pipe_no_transition(pipe_no_transition), .emg_ovr_en(emg_ovr_en), .emg_ovr_bank(emg_ovr_bank), .emg_ovr_black(emg_ovr_black),
    .pipe_fx_effect(pipe_fx_effect), .pipe_fx_speed(pipe_fx_speed),
    .geo_stepx(geo_stepx), .geo_startx(geo_startx), .geo_stepy(geo_stepy), .geo_starty(geo_starty),
    .geo_mirror(geo_mirror), .geo_flip(geo_flip), .auto_run(auto_run), .pipe_brightness(pipe_brightness), .pipe_contrast(pipe_contrast),
    .thumb_key_right(thumb_key_right), .thumb_key_left(thumb_key_left),
    .thumb_key_confirm(thumb_key_confirm), .thumb_key_mode(thumb_key_mode), .bc_freeze(bc_freeze),
    .cpr_active(cpr_active), .cpr_state(cpr_state), .cpr_mode_302(cpr_mode_302), .cpr_breath(cpr_breath), .cpr_beat(cpr_beat), .key_tick(key_tick),
    .cpr_timer_bcd(cpr_timer_bcd), .cpr_aed_time_bcd(cpr_aed_time_bcd), .sw1_on(), .sw4_on(),
    .page(ui_page), .menu_visible(menu_visible), .hint_show(hint_show), .hint_leave(hint_leave), .txt_we(), .txt_addr(), .txt_data(),
    .vol_gain(menu_vol_gain), .vw_viz(), .status_osd_en(status_osd_en)
);

// ---------------- 期望像素 ----------------
integer errors = 0;

function integer pic_of_bank;          // bank n 里应该是 PIC 几
    input integer bank;
    begin
`ifdef MISSING3
        pic_of_bank = (bank >= 2) ? bank + 2 : bank + 1;
`else
        pic_of_bank = bank + 1;
`endif
    end
endfunction

`ifdef MISSING6
localparam integer HAS6 = 0;
`else
localparam integer HAS6 = 1;
`endif
localparam integer EMG_PIC = HAS6 ? 6 : 0;   // 急救全程（① ② ③ 交接页）应显示的图（0 = 黑底）

function [23:0] expect_rgb;            // 显示第 y 行第 x 列
    input integer pic; input integer y; input integer x;
    integer fr;
    begin
        fr = H - 1 - y;                // BMP 文件内行号（自下而上）
        expect_rgb = {8'ha0 + pic[7:0], x[7:0], pic[1:0], fr[5:0]};
    end
endfunction

// R5 画面变换的期望值：与 geom_param 同样的 16.16 映射（中心缩放 + 平移，镜像 / 翻转，越界黑）
reg     geo_on = 1'b0;
reg     geo_chg = 1'b0;      // 改参数期间（跨两帧）不做逐像素检查：参数在哪一帧生效取决于改的时刻
integer g_qx = 4, g_qy = 4, g_px = 0, g_py = 0;
reg     g_mx = 1'b0, g_fy = 1'b0;
function [23:0] geo_expect;
    input integer pic; input integer y; input integer x;
    integer stx, sty, u, v;
    reg signed [63:0] ax, ay;
    begin
        stx = (1 << 22) / (g_qx * 16);  sty = (1 << 22) / (g_qy * 16);
        ax = ((W / 2) <<< 16) - (W / 2) * stx + ((g_px * 16) <<< 16) + x * stx;
        ay = ((H / 2) <<< 16) - (H / 2) * sty + ((g_py * 16) <<< 16) + y * sty;
        u = ax >>> 16;  v = ay >>> 16;
        if (u < 0 || u >= W || v < 0 || v >= H) geo_expect = 24'h000000;
        else geo_expect = expect_rgb(pic, g_fy ? H - 1 - v : v, g_mx ? W - 1 - u : u);
    end
endfunction

// FADE16：转场乘法在稳态 alpha=255、亮度 255 时是 x*255>>8（比原值暗 1 LSB，板上一直如此），期望值同样换算
function [23:0] disp_rgb;
    input [23:0] c;
    begin
`ifdef FADE16
        disp_rgb = {c[23:16] - (c[23:16] != 0), c[15:8] - (c[15:8] != 0), c[7:0] - (c[7:0] != 0)};
`else
        disp_rgb = c;
`endif
    end
endfunction

// ---------------- 逐帧检查显示 ----------------
integer px = 0, py = 0;
integer frame_no = 0;
integer frame_pic = -1, frame_bad = 0, frame_mixed = 0;
integer thumb_frames = 0;              // 逐像素正确的缩略图帧数
reg     frame_is_thumb = 1'b0;         // 本帧按缩略图检查（取帧开始时像素域锁存的模式）
integer q, lx, ly, cw;
reg [23:0] exp_px;
// 第9课起左上角 (8,8) 起两行 OSD 字（32x18），不参与像素比对
wire osd_area = (px >= 8 && px < 40 && py >= 8 && py < 26);
integer last_frame_pic = -1;
reg     frame_cpr = 1'b0;          // FADE16：本帧开始时在急救中（只有这些帧必须整帧精确）
reg     frame_black = 1'b0;        // R7b-1：本帧被急救覆盖成黑底（MISSING6），整帧必须全黑
integer good_frames = 0;
reg     frame_checked = 1'b0;       // 本帧开始时显示已经打开（打开那一刻正在进行的那一帧是黑的，不检查）
reg     v_de_q = 1'b0, v_vs_q = 1'b1;
integer b, p;
// R12c 推移转场（FADE16）：reader 锁存了推移的帧，按「旧图一段 + 新图一段」逐像素检查
reg     pf_active = 1'b0, pf_h = 1'b0;
integer pf_old = 0, pf_new = 0, pf_off = 0, pf_bad = 0, push_frames = 0, push_err = 0, pk0 = 0, pk1 = 0;
reg [23:0] pf_exp;
reg [1023:0] pname;
always @(posedge pix_clk) begin
    v_vs_q <= v_vs;
    v_de_q <= v_de;
    if (v_vs_q && !v_vs) begin          // vsync 下降沿：上一帧结束
        if (pf_active) begin
            if (pf_bad != 0) begin
                $display("  [t=%0d us] 推移帧 %0d（%0s off %0d，PIC%0d -> PIC%0d）：错 %0d 像素", $time / 1000, frame_no,
                         pf_h ? "向左" : "向上", pf_off, pf_old, pf_new, pf_bad);
                push_err = push_err + 1;  errors = errors + 1;
            end else
                push_frames = push_frames + 1;
        end
        pf_active = 1'b0;  pf_bad = 0;
`ifdef FADE16
        if (!frame_cpr) begin
            if (frame_checked && frame_bad == 0 && frame_mixed == 0 && !frame_is_thumb) last_frame_pic = frame_pic;
        end else
`endif
        if (frame_checked && frame_is_thumb) begin
            if (frame_bad != 0) begin
                $display("  [t=%0d us] 缩略图帧 %0d：错 %0d 像素（焦点 %0d）", $time / 1000, frame_no, frame_bad, u_pipe.focus_pix);
                errors = errors + 1;
            end else begin
                thumb_frames = thumb_frames + 1;
                if (thumb_frames == 1 || last_frame_pic != 100 + u_pipe.focus_pix)
                    $display("  [t=%0d us] 显示缩略图（焦点 %0d，整帧逐像素正确）", $time / 1000, u_pipe.focus_pix);
            end
            last_frame_pic = 100 + u_pipe.focus_pix;
        end else if (frame_checked) begin
            if (frame_bad != 0 || frame_mixed != 0) begin
                $display("  [t=%0d us] 帧 %0d：PIC%0d 错 %0d 像素，混帧 %0d", $time / 1000, frame_no, frame_pic, frame_bad, frame_mixed);
                errors = errors + 1;
            end else begin
                good_frames = good_frames + 1;
                if (frame_pic != last_frame_pic)
                    $display("  [t=%0d us] 显示 PIC%0d（帧 %0d，整帧逐像素正确）", $time / 1000, frame_pic, frame_no);
            end
            last_frame_pic = frame_pic;
        end
        frame_no = frame_no + 1;
        // 对比度不是 128 / 色彩不是标准 / 交接页（压暗）时画面本来就被调过，不做逐像素比对（色彩另有 tb_bc_sat 逐位检查）
        frame_checked = display_valid && pipe_contrast == 8'd128 && pipe_sat == 2'd2 && !geo_chg && cpr_state != 3'd4;
        frame_cpr = cpr_active;
        frame_black = u_pipe.ovr_en_pix && u_pipe.ovr_black_pix;   // 像素域已在本帧 frame_start 锁存
        frame_is_thumb = 1'b0;
        frame_pic = -1; frame_bad = 0; frame_mixed = 0;
        py = 0; px = 0;
    end
    if (v_de && py == 0 && px == 0) begin
        frame_is_thumb = u_pipe.view_pix;   // rgb_video_adapter 晚一拍，此时像素域已锁存本帧模式
        pf_active = display_valid && frame_checked && u_pipe.u_reader.request_push_pix;   // reader 在 frame_start 后第 7 拍锁存
        pf_h   = u_pipe.u_reader.request_ph_pix;
        pf_old = pic_of_bank(u_pipe.u_reader.request_old_pix);
        pf_new = pic_of_bank(u_pipe.u_reader.request_index_pix);
        pf_off = u_pipe.u_reader.request_off_pix;
    end
    if (v_de && pf_active && !frame_is_thumb) begin
        if (pf_h) pf_exp = (px < W - pf_off) ? expect_rgb(pf_old, py, px + pf_off) : expect_rgb(pf_new, py, px - (W - pf_off));
        else      pf_exp = (py < H - pf_off) ? expect_rgb(pf_old, py + pf_off, px) : expect_rgb(pf_new, py - (H - pf_off), px);
        if (v_rgb !== disp_rgb(pf_exp) && !osd_area) begin
            if (pf_bad < 3) $display("    推移像素 (%0d,%0d) = %h，应为 %h（off %0d）", px, py, v_rgb, disp_rgb(pf_exp), pf_off);
            pf_bad = pf_bad + 1;
        end
    end
    if (v_de && frame_is_thumb) begin
        // R11 2x2：格 W/2 x H/2；第 k 个像素 = 左右两格源行拼接后第 2k、2k+1 个字的平均，源行 = 2 × 格内行号
        //   （测试图 G = 列号，第 2c、2c+1 列平均取整 = 2c，所以期望值 = 第 2c 列；读错成第 2c+1 列会被查出来）
        q  = ((px < W / 2) ? 0 : 1) + ((py < H / 2) ? 0 : 2);
        lx = px % (W / 2);
        cw = W / 2;
        ly = py % (H / 2);
        if (q >= n_img_g)
            exp_px = 24'h000000;
        else if ((lx < 2 || ly < 2 || lx >= cw - 2 || ly >= H / 2 - 2) && q == u_pipe.focus_pix)
            exp_px = 24'hffd000;
        else
            exp_px = expect_rgb(pic_of_bank(q), 2 * ly, 2 * lx);
        if (v_rgb !== exp_px && !osd_area) begin
            if (frame_bad < 3)
                $display("    像素 (%0d,%0d) = %h，应为 %h", px, py, v_rgb, exp_px);
            frame_bad = frame_bad + 1;
        end
        px = px + 1;
    end else if (v_de) begin
        if (frame_pic < 0) begin
            frame_pic = 0;
            for (p = 1; p <= 6; p = p + 1) if (v_rgb[23:16] == disp_rgb({8'ha0 + p[7:0], 16'h0}) >> 16) frame_pic = p;
            if (geo_on) frame_pic = pic_of_bank(active_index);   // 变换后第一个像素可能是黑边，按当前 bank 取
        end
        if (v_rgb !== ((frame_black && frame_pic == 0) ? 24'h000000 :
                       disp_rgb(geo_on ? geo_expect(frame_pic, py, px) : expect_rgb(frame_pic, py, px))) && !osd_area) begin
            if (geo_on && frame_checked && frame_bad < 4)
                $display("    G 像素 (%0d,%0d) = %h，应为 %h", px, py, v_rgb, disp_rgb(geo_expect(frame_pic, py, px)));
            if (v_rgb[23:16] != disp_rgb({8'ha0 + frame_pic[7:0], 16'h0}) >> 16) frame_mixed = frame_mixed + 1;
            else frame_bad = frame_bad + 1;
        end
        px = px + 1;
    end else if (v_de_q) begin
        px = 0; py = py + 1;
    end
end

// ---------------- 工具 ----------------
task geo_set(input m, input f, input integer qx, input integer qy, input integer px_, input integer py_);
    begin
        geo_chg = 1'b1;
        frame_checked = 1'b0;          // 正在画的这一帧也不检查（参数可能在帧中途被读走）
        u_router.u_menu.vw_mirror = m;  u_router.u_menu.vw_flip = f;
        u_router.u_menu.vw_sx = qx;  u_router.u_menu.vw_sy = qy;
        u_router.u_menu.vw_panx = px_;  u_router.u_menu.vw_pany = py_;
        wait_frames(3);
        geo_on = 1'b1;  g_mx = m;  g_fy = f;  g_qx = qx;  g_qy = qy;  g_px = px_;  g_py = py_;
        geo_chg = 1'b0;
        wait_frames(1);
    end
endtask
task wait_ms(input integer ms);
    begin repeat (ms * CPMS) @(posedge sd_clk); end
endtask
task wait_frames(input integer n);
    integer f0;
    begin f0 = frame_no; while (frame_no < f0 + n) @(posedge pix_clk); end
endtask
task press(input integer which, input integer hold_ms);
    begin
        if (which == 0) key_next = 1'b0; else key_auto = 1'b0;
        wait_ms(hold_ms);
        if (which == 0) key_next = 1'b1; else key_auto = 1'b1;
        wait_ms(100);
    end
endtask
// R1.5b：菜单 / 提示条文字是中文宏（include/ui_text.vh），和屏幕上的整行比较。
// R8-0b：page_menu_ctrl 不再有整行寄存器，tb 在写文字 RAM 的窗口（每 1024 拍的第 0~415 拍）把生成器逐字节输出收进
//   txt_stage，第 416 拍整体复制到 txt_line（= 原来的 t_s1/t_s2/t_m1/t_m2/t_h/字幕/故障条，比原来晚约 1400 拍）
// R8-2b：生成器多一行状态栏 3（第 208~231 字节），窗口到第 463 拍，第 464 拍复制（txt_s3 单独放）
reg  [7:0]    txt_stage [0:231];
// R8-2b：路由器发出过转场预览请求（M5b 用；本 tb 默认 FADE_FRAMES=0 转场直通，预览不动画面，
//   同一张图"消失 -> 出现"在 tb_transition E6 逐帧检查）
reg           pv_seen = 1'b0;
always @(posedge sd_clk) if (pipe_preview_event) pv_seen <= 1'b1;
reg  [1663:0] txt_line;
reg  [191:0]  txt_s3;
reg  [15:0]   txt_ctmr;
integer       ti;
always @(posedge sd_clk) begin
    if (u_router.u_menu.pub_cnt < 10'd464 && !u_router.u_menu.pub_cnt[0])
        txt_stage[u_router.u_menu.pub_cnt[9:1]] <= u_router.u_menu.gbyte;
    if (u_router.u_menu.pub_cnt == 10'd464) begin
        for (ti = 0; ti < 208; ti = ti + 1) txt_line[1663 - 8 * ti -: 8] <= txt_stage[ti];
        for (ti = 0; ti < 24; ti = ti + 1) txt_s3[191 - 8 * ti -: 8] <= txt_stage[208 + ti];
        txt_ctmr <= u_router.u_menu.q_ctmr;
    end
end
wire [191:0] txt_m1 = txt_line[1279:1088];
`define M1 txt_m1
wire [191:0] txt_m2 = txt_line[1087:896];
`define M2 txt_m2
wire [191:0] txt_h  = txt_line[895:704];
`define HT txt_h
task show_menu;
    begin
        $display("    菜单可见=%0d 提示码=%0d show=%0d leave=%0d", menu_visible, u_router.u_menu.hint, hint_show, hint_leave);
    end
endtask
task k3_click;
    begin key3 = 1'b0; wait_ms(200); key3 = 1'b1; wait_ms(100); end
endtask
task k1_click;
    begin key0 = 1'b0; wait_ms(200); key0 = 1'b1; wait_ms(100); end
endtask
integer pv_a, pv_n, pv_auto;
// R7a：节拍计数（cpr_beat 单拍）
integer n_beat = 0;
always @(posedge sd_clk) if (cpr_beat) n_beat = n_beat + 1;
// R7c-1：按键音触发计数；节拍音按顶层接法过 cue_tone_gen，数它在音频域收到几次节拍触发
//   （tb 里控制域时间缩小 1000 倍，一拍才约 545us，60ms 的节拍音来不及响完，所以数触发而不是数声音；音色 / 时长见 tb_cue_tone）
integer n_key = 0, n_beep = 0;
always @(posedge sd_clk) if (key_tick) n_key = n_key + 1;
reg [24:0] aud_acc = 0;
wire       aud_tick = (aud_acc >= 25'd25_000_000 - 25'd48_000);
always @(posedge pix_clk) aud_acc <= aud_tick ? aud_acc + 25'd48_000 - 25'd25_000_000 : aud_acc + 25'd48_000;
wire       beep_on;
cue_tone_gen u_cue (
    .src_clk(sd_clk), .src_rst_n(sdcard_rst_n), .beat_pulse(cpr_beat), .key_pulse(key_tick), .blow_level(u_router.cpr_blow),
    .clk(pix_clk), .rst_n(video_rst_n), .sample_tick(aud_tick), .mix_in(16'sd0), .mix_out(), .cue_sample(),
    .beat_on(beep_on), .key_on()
);
always @(posedge pix_clk) if (u_cue.bt_s[2] ^ u_cue.bt_s[1]) n_beep = n_beep + 1;
// R12d：吹气音只在人工呼吸吹气那两秒（cpr_blow）；按压时数 cpr_blow 为高的拍数，应为 0（R12a 接 LED，每拍都响）
integer n_blow_cpr = 0;
always @(posedge sd_clk) if (u_router.cpr_blow && !cpr_breath) n_blow_cpr = n_blow_cpr + 1;
// R12d：图片读完前 DE 照常输出（HDMI 有有效视频期，开机读图黄框 / 没卡故障条才画得出来），像素是黑的
integer n_pre_de = 0, n_pre_lit = 0;
always @(posedge pix_clk) if (!display_valid && v_de) begin
    n_pre_de = n_pre_de + 1;
    if (v_rgb != 24'h000000 && pipe_contrast == 8'd128 && pipe_sat == 2'd2) n_pre_lit = n_pre_lit + 1;   // SAVE 开机套用低对比度时黑会抬成灰，不算
end
function [15:0] bcd4;
    input integer v;
    begin
        bcd4[15:12] = v / 1000 % 10;  bcd4[11:8] = v / 100 % 10;  bcd4[7:4] = v / 10 % 10;  bcd4[3:0] = v % 10;
    end
endfunction
function [39:0] mmss;                  // mm:ss BCD -> "mm:ss"
    input [15:0] v;
    mmss = {4'h3, v[15:12], 4'h3, v[11:8], ":", 4'h3, v[7:4], 4'h3, v[3:0]};
endfunction
function [31:0] asc4;                  // BCD 4 位 -> ASCII
    input [15:0] v;
    asc4 = {4'h3, v[15:12], 4'h3, v[11:8], 4'h3, v[7:4], 4'h3, v[3:0]};
endfunction
wire [191:0] txt_s1 = txt_line[1663:1472];
`define S1 txt_s1
wire [191:0] txt_s2 = txt_line[1471:1280];
`define S2 txt_s2
wire [191:0] txt_f  = txt_line[191:0];
`define S3 txt_s3
// R8-2b 显示页菜单框（只写按键名）/ 状态栏第三行
`define M1D {"K1", `T_S_BRI, {6{8'h20}}, "K2", `T_S_CON, {4{8'h20}}}
`define M2D {"K3", `T_D_COLOR, {6{8'h20}}, "K4", `T_D_SUB, "/", `T_D_GAP, " "}
`define S3L(sat, sc, sec) {`T_D_COLOR, sat, " ", `T_D_SUB, sc, " ", `T_D_GAP, sec, `T_D_SEC}
`define FT txt_f
// R9 急救文字：状态栏第 1 行（本 tb 没有 GUIDE.WAV -> 无语音）/ 第 2 行 / 底栏带数字的句子
`define S1C(t) {`T_C_PAST, " ", t, "  ", `T_C_VN, "  "}
`define S2C(g, n) {"30:2 ", `T_C_GRP1, g, `T_C_GRP2, " ", `T_C_COMP, n, `T_C_TIMES, "  "}
`define S2P(n) {`T_C_PURE, " ", `T_C_COMP, n, `T_C_TIMES, {5{8'h20}}}
`define HLOOK(d) {{5{8'h20}}, `T_B_LOOK, " ", d, {5{8'h20}}}
`define HPRESS(c) {{4{8'h20}}, `T_B_PRESS, " ", c, "/30", {4{8'h20}}}
`define HBR(d) {{5{8'h20}}, `T_B_BREATH, " ", d, "/2", {5{8'h20}}}
function [15:0] cyc2;                  // 本组第几下 -> 2 个字符（十位是 0 时空格）
    input integer v;
    reg [7:0] hi, lo;
    begin
        hi = (v >= 10) ? 8'h30 + v / 10 : 8'h20;  lo = 8'h30 + v % 10;
        cyc2 = {hi, lo};
    end
endfunction
// R8-4b：最近一次写入的扇区：魔数 / 版本 / 校验对，亮度、开关位、急救次数符合，32 字节以后全 0
function save_ok(input [7:0] bri, input [7:0] flags, input [7:0] cnt);
    integer i; reg [7:0] x; reg z;
    begin
        x = 8'd0;  z = 1'b1;
        for (i = 0; i < 32; i = i + 1) x = x ^ dut.sd_card_top_m0.wsec[i];
        for (i = 32; i < 512; i = i + 1) if (dut.sd_card_top_m0.wsec[i] != 8'd0) z = 1'b0;
        save_ok = z && x == 8'd0 && dut.sd_card_top_m0.wsec[0] == "C" && dut.sd_card_top_m0.wsec[1] == "P" && dut.sd_card_top_m0.wsec[2] == "R" && dut.sd_card_top_m0.wsec[3] == "S" &&
                  dut.sd_card_top_m0.wsec[4] == 8'd1 && dut.sd_card_top_m0.wsec[5] == bri && dut.sd_card_top_m0.wsec[10] == flags && dut.sd_card_top_m0.wsec[24] == cnt;
    end
endfunction
task check(input ok, input [1023:0] what);
    begin
        if (ok) $display("  ok   %0s", what);
        else begin $display("  FAIL %0s", what); errors = errors + 1; end
    end
endtask

integer k, n_img, bad_words, y, x, k_pic, cpr_pic, nb0, nk0, nbp0;
integer n_img_g = 4;
initial begin
`ifdef MISSING3
    n_img = 3;
`else
    n_img = 4;                                         // R11：卡上有 PIC5 也不加载
`endif
    n_img_g = n_img;
    #100 rst_n = 1'b1;

`ifdef NOCARD
    wait_ms(3000);
    check(fault_code == 4'd1 && display_valid == 1'b0, "R0 no card at boot -> fault 1 (no TF card), display off");
    check(n_pre_de >= W * H && n_pre_lit == 0, "R0 no card: DE still running (black frames) so the fault banner can be drawn (R12d)");
    press(1, 200);                                     // R7b-2：没插卡也能急救（黑底 + 文字）
    wait_ms(20);
    check(cpr_state == 3'd1 && emg_ovr_en && display_valid == 1'b0, "N1 no card: K4 click -> part 1 CALL");
    check(fault_code == 4'd0 && `HT == `T_H_C_1Z && `M1 == `T_C_T1Za && menu_visible, "N1 fault banner suppressed in CPR, CPR text shown");
    k3_click;
    check(cpr_state == 3'd2 && emg_ovr_black, "N2 K3 -> part 2 (no PIC6 -> black)");
    press(0, 200);
    check(cpr_mode_302 == 1'b0, "N2 K2 -> 单纯按压 without card (default 30:2)");
    press(1, 2100);
    check(cpr_state == 3'd4, "N3 K4 2s hold -> SUMMARY without card");
    press(1, 2100);
    wait_ms(20);
    check(cpr_state == 3'd0 && fault_code == 4'd1, "N3 back to standby, no-card fault shown again");
    card_in = 1'b1;                                    // 插卡：初始化看门狗下次重试时成功，接着正常加载
`endif
    wait (loader_load_start && loader_image_index == 3'd1);   // R12：读第 2 张时正中黄框「正在读取图片 2/n」
    repeat (40) @(posedge sd_clk);
    check(fault_code == 4'd14 && fault_arg == 3'd1 && fault_tot == n_img + HAS6 && u_router.note_show && !fault_show && !display_valid,
          "B00 loading: centre note 正在读取图片 2/n (code 14, yellow, not a fault)");
    check(n_pre_de >= W * H && n_pre_lit == 0, "B00 loading: DE running before display opens, pixels black (R12d: the note box is visible)");
    wait (display_valid == 1'b1);
    $display("  [t=%0d us] 打开显示：找到 %0d 张，image_complete=%b，写 SDRAM %0d 字，读写重叠 %0d 次",
             $time / 1000, img_found_count, loader_image_complete, n_wr, n_wr_overlap);
    check(img_found_count == n_img, "B0 found image count");
    check(loader_image_complete == ((1 << n_img) - 1), "B0 image_complete bits");
    check(n_wr == (n_img + HAS6) * WORDS, "B0 SDRAM write count = (n_img + PIC6) * 3072");
    check(emg_ok == HAS6 && tf_found_mask[5] == HAS6, "B0 PIC6 (emergency image) found / loaded into bank5");
    check(n_wr_overlap == 0, "B0 no read during write");
    bad_words = 0;
    for (b = 0; b < n_img; b = b + 1)
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1)
                if (sdram[b * WORDS + y * W + x] !== {8'h00, expect_rgb(pic_of_bank(b), y, x)}) bad_words = bad_words + 1;
    if (HAS6)
        for (y = 0; y < H; y = y + 1)
            for (x = 0; x < W; x = x + 1)
                if (sdram[5 * WORDS + y * W + x] !== {8'h00, expect_rgb(6, y, x)}) bad_words = bad_words + 1;
    check(bad_words == 0, "B1 every bank holds its picture (bank5 = PIC6), rows flipped");
    wait_ms(20);                                       // R8-0b：文字比原来晚约 14ms 才进 txt_line
`ifdef MISSING6
    check(fault_code == 4'd12 && `FT == `T_F_MISS6, "R1 warning on display open: missing emergency image PIC6.BMP");
`elsif MISSING3
    check(fault_code == 4'd8 && fault_arg == 3'd2 && `FT == `T_F_MISS3, "R1 warning on display open: missing PIC3.BMP");
`else
    check(fault_code == 4'd10, "R1 warning on display open: no MUSIC.WAV");
`endif
`ifdef NOCARD
    $display("RESULT: %0s（%0d 个失败）", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
`endif
`ifdef SAVE
    // R8-4a：SAVE.BIN = 亮度 128 对比度 192 色彩鲜艳 字幕色 5 间隔 1 秒 状态栏开 字幕开 轮播关 镜像开 频谱 效果 5 速度 6 音量 4 当前图 bank2
    wait_frames(3);
    check(menu_brightness == 8'd128 && menu_contrast == 8'd192 && u_router.menu_sat == 2'd3 &&
          u_router.sub_color == 3'd5 && u_router.auto_int == 3'd0, "S1 display page settings restored from SAVE.BIN");
    check(u_router.stat_on && u_router.u_menu.ly_show[1] && !u_router.auto_on && u_router.u_menu.vw_mirror && !u_router.u_menu.vw_flip,
          "S1 switches restored: status bar on, subtitle on, autoplay off, mirror on");
    check(u_router.u_menu.vw_viz == 3'd0 && u_router.u_menu.fx_effect == 4'd5 && u_router.u_menu.fx_speed == 4'd6 &&
          u_router.u_menu.vw_volume == 4'd4, "S1 transition / volume restored, visualizer NOT restored (R10: always off at boot)");
    // 存档开了镜像，逐像素比对（按不镜像算）不适用，只看 bank 号和镜像输出
    check(active_index == 3'd2 && geo_mirror && !geo_flip, "S2 boot jumps to saved picture (bank2), mirrored");
    check(n_wr == (n_img + HAS6) * WORDS, "S3 all pictures still loaded");
    // ---- R8-4b：写回 ----
    check(`HT != {`T_H_LAST0, "05:32 ", `T_C_COMP, "0312", `T_C_TIMES}, "S5 R9: no boot hint 上次急救 (rescue record removed)");
    wait_ms(2000);
    check(dut.sd_card_top_m0.n_writes == 0, "S6 no write at boot (restoring the saved settings / picture is not a change)");
    sw1 = 1'b1; wait_ms(60);
    k1_click;                                          // 显示页 K1：亮度 128 -> 64
    wait_ms(1000);
    check(menu_brightness == 8'd64 && dut.sd_card_top_m0.n_writes == 0, "W1 brightness changed, no write within 3 s");
    wait_ms(2600);
    check(dut.sd_card_top_m0.n_writes == 1 && dut.sd_card_top_m0.n_bad_wr == 0 && save_ok(8'd64, 8'h0b, 8'd0), "W1 3 s later: one write to SAVE.BIN sector, brightness 64, checksum ok");
    key0 = 1'b0; wait_ms(3200); key0 = 1'b1; wait_ms(60);   // 显示页 K1 长按 3 秒：恢复默认
    check(menu_brightness == 8'd255 && menu_contrast == 8'd128 && u_router.menu_sat == 2'd2 && !u_router.stat_on &&
          !u_router.u_menu.ly_show[1] && !u_router.u_menu.vw_mirror && u_router.u_menu.vw_viz == 3'd0 &&
          u_router.u_menu.vw_volume == 4'd6 && `HT == `T_H_FRST, "F1 K1 hold 3 s on display page -> defaults, hint 已恢复默认设置");
    wait_ms(4000);
    check(dut.sd_card_top_m0.n_writes >= 2 && dut.sd_card_top_m0.n_writes <= 3 && dut.sd_card_top_m0.n_bad_wr == 0 && save_ok(8'd255, 8'h00, 8'd0),
          "F1 defaults written (brightness 255, all switches off, record bytes 0)");
    nk0 = dut.sd_card_top_m0.n_writes;
    sw1 = 1'b0; wait_ms(60);
    press(1, 200); wait_ms(500);                       // K4 单击：进急救 ① 呼救
    k3_click; wait_ms(1000);                           // K3：② 按压（① 里 K4 长按 = 误触取消，不进交接页）
    check(cpr_active && cpr_state == 3'd2 && dut.sd_card_top_m0.n_writes == nk0, "W2 no write while rescuing");
    press(1, 2100); wait_ms(60);                       // K4 长按 2 秒：交接页
    check(cpr_state == 3'd4 && dut.sd_card_top_m0.n_writes == nk0, "W2 R9: summary page -> no write (rescue record removed)");
    press(1, 2100); wait_ms(4000);
    // R9：进急救那一下 K4 是在待机时按的，算"设置可能变了"；原来交接页写急救记录时顺带清掉，现在回到待机 3 秒后照常写一次（内容就是当前设置）
    check(cpr_state == 3'd0 && dut.sd_card_top_m0.n_writes == nk0 + 1 && dut.sd_card_top_m0.n_bad_wr == 0 && save_ok(8'd255, 8'h00, 8'd0),
          "W3 back to standby: settings written once 3 s later (pending K4 press), checksum ok");
    check(reader_underflow == 1'b0 && video_error == 8'd0, "W4 no underflow / reader error");
    $display("RESULT: %0s（%0d 个失败）", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
`endif
`ifdef SAVEBAD
    wait_frames(3);
    check(menu_brightness == 8'd255 && menu_contrast == 8'd128 && u_router.menu_sat == 2'd2 && !u_router.stat_on &&
          u_router.u_menu.vw_viz == 3'd0 && active_index == 3'd0, "S4 bad checksum -> defaults, bank0");
    $display("RESULT: %0s（%0d 个失败）", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
`endif

`ifndef FADE16
    wait_frames(3);
    check(active_index == 2'd0 && last_frame_pic == pic_of_bank(0), "T0 boot shows bank0");

    for (k = 1; k <= n_img; k = k + 1) begin
        press(0, 200);                                 // K2 单击：下一张
        wait_frames(3);
        check(active_index == k % n_img && last_frame_pic == pic_of_bank(k % n_img), "T1 K2 click -> next bank");
        if (k == 1) check(`HT == `T_H_NEXT, "T1 hint 下一张");
    end

    press(0, 1200);                                    // K2 长按：上一张
    wait_frames(3);
    check(active_index == n_img - 1 && last_frame_pic == pic_of_bank(n_img - 1), "T2 K2 hold -> prev (last bank)");
    check(`HT == `T_H_PREV, "T2 hint 上一张");

    k1_click;                                          // R7a：K1 单击 = 自动轮播开
    check(auto_run == 1'b1 && thumb_view == 1'b0 && cpr_active == 1'b0, "T3 K1 click -> autoplay on (no thumbnail, no CPR)");
    check(hint_show && `HT == `T_H_AUTO_ON && menu_visible == 1'b0, "T3 hint 自动轮播 开启 (menu stays hidden)");
    wait_ms(3500);
    wait_frames(2);
    check(active_index == 2'd0, "T3 autoplay advanced to bank0");
    k1_click;                                          // K1 单击：自动轮播关
    check(auto_run == 1'b0, "T3 K1 click again -> autoplay off");
    check(hint_show && `HT == `T_H_AUTO_OFF, "T3 hint 自动轮播 关闭");
    wait_frames(3);
    check(active_index == 2'd0 && auto_run == 1'b0 && auto_enabled == 1'b0 && thumb_view == 1'b0, "T3 autoplay stopped at bank0, no thumbnail (player-internal autoplay stays off)");
    check(status_osd_en == 1'b0, "T3 old ASCII status OSD off (replaced by Chinese status bar)");
    check(`S1[191:160] == `T_S_AUTO && `S2[191:160] == `T_S_BRI, "T3 status bar 轮播 / 亮度");

    check(reader_underflow == 1'b0 && video_error == 8'd0, "T4 no underflow / reader error");
    check(n_wr == (n_img + HAS6) * WORDS, "T4 no SDRAM write after display on");
    check(n_rw_in_refresh == 0, "T4 no SDRAM read/write during refresh");

    // ---- 缩略图（CPR 按键改版：K4 长按进出，K2 单击右移 / 长按左移，K4 单击确认）----
    press(1, 1200);                                    // K4 长按：进入缩略图
    wait_frames(4);
    check(thumb_view == 1'b1 && u_pipe.view_pix == 1'b1, "T5 K4 hold -> thumbnail mode");
    check(thumb_frames >= 2, "T5 thumbnail frames pixel-exact (2x2, 2-pixel average, focus border on bank0)");
    press(0, 200);                                     // K2 单击：焦点右移
    wait_frames(3);
    check(thumb_focus == 3'd1 && u_pipe.focus_pix == 3'd1, "T6 K2 click -> focus 1");
    press(0, 1200);                                    // K2 长按 x2：焦点左移 -> 0 -> wrap 到 3（R11：4 张）
    press(0, 1200);
    wait_frames(3);
    check(thumb_focus == 3'd3, "T6 K2 hold x2 -> focus wraps 1->0->3");
    press(1, 200);                                     // K4 单击：确认
    wait_frames(4);
    if (n_img == 4)
        check(thumb_view == 1'b0 && active_index == 3'd3 && last_frame_pic == pic_of_bank(3), "T7 K4 click confirm -> fullscreen bank3 (PIC4)");
    else
        check(thumb_view == 1'b1, "T7 K4 click confirm on empty slot ignored");
    press(1, 1200);
    wait_frames(3);
    if (n_img != 4) begin
        check(thumb_view == 1'b0, "T8 K4 hold -> back to fullscreen");
    end else begin
        check(thumb_view == 1'b1, "T8 K4 hold -> thumbnail again");
        press(1, 1200);
        wait_frames(3);
        check(thumb_view == 1'b0 && last_frame_pic == pic_of_bank(3), "T8 K4 hold -> back, still bank3");
    end
    check(reader_underflow == 1'b0 && video_error == 8'd0, "T9 no underflow / reader error in thumbnail mode");

    // ---- CPR 第 1 轮：急救流程 ----
    // ---- R8-2：播放模式 K3 单击 = 字幕开 / 关；亮度 / 对比度 / 色彩 / 字幕颜色 / 轮播间隔 在显示页（SW1 开、页 00）----
    // R8-2b：上电字幕关、状态栏关
    check(u_router.u_menu.ly_show[1] == 1'b0 && u_router.stat_on == 1'b0, "C0 power-on: subtitle off, status bar off (R8-2b)");
    k3_click;
    wait_ms(20);
    check(cpr_active == 1'b0 && u_router.u_menu.ly_show[1] == 1'b1 && hint_show && `HT == `T_H_SUB1 && menu_brightness == 8'd255 && !u_router.stat_on,
          "C0 play mode K3 click -> subtitle on, hint 字幕 开启 (no CPR, brightness / status bar untouched)");
    k3_click;
    wait_ms(20);
    check(u_router.u_menu.ly_show[1] == 1'b0 && `HT == `T_H_SUB0, "C0 K3 again -> subtitle off, hint 字幕 关闭");
    key3 = 1'b0; wait_ms(1200); key3 = 1'b1; wait_ms(100);    // K3 长按
    check(u_router.stat_on == 1'b1 && u_router.u_menu.ly_show[1] == 1'b0 && `HT == `T_H_STAT1 && `S3 == `S3L(`T_SAT2, `T_SC0, " 3"),
          "C0 K3 hold -> status bar on, hint 状态栏 开启, row 3 色彩标准 字幕白 间隔 3秒 (subtitle untouched)");
    // R11：播放模式 K1 按满 1 秒 = 频谱 开 / 关（松开不算单击，轮播不变）
    k = u_router.auto_on;
    key0 = 1'b0; wait_ms(1500); key0 = 1'b1; wait_ms(60);
    check(u_router.u_menu.vw_viz == 3'd2 && u_router.auto_on == k && `HT == `T_H_VIZ1, "C0 play mode K1 hold 1 s -> spectrum on, hint 频谱 开启, autoplay untouched");
    key0 = 1'b0; wait_ms(1500); key0 = 1'b1; wait_ms(60);
    check(u_router.u_menu.vw_viz == 3'd0 && u_router.auto_on == k && `HT == `T_H_VIZ0, "C0 K1 hold again -> spectrum off, hint 频谱 关闭");
    sw1 = 1'b1; wait_ms(60);
    check(menu_visible && u_router.menu_disp && `M1 == `M1D && `M2 == `M2D,
          "C0 display page: menu box K1亮度      K2对比度 / K3色彩      K4字幕/间隔 (no values, white)");
    k1_click; wait_ms(20);
    check(menu_brightness == 8'd192 && pipe_brightness == 8'd192 && `HT == `T_H_BRI3 && `M1 == `M1D && `S2[191:160] == `T_S_BRI,
          "C0 display page K1 -> brightness 192 (level 3) reaches pipeline, hint 亮度 3");
    // R11：显示页 K1 按 1.5 秒松开 = 还是亮度 +1 档（频谱档去掉），满 3 秒才恢复默认
    key0 = 1'b0; wait_ms(1500); key0 = 1'b1; wait_ms(60);
    check(u_router.u_menu.vw_viz == 3'd0 && menu_brightness == 8'd128, "C0 display page K1 1.5 s -> brightness 128, spectrum untouched");
    for (k = 0; k < 3; k = k + 1) k1_click;            // 128 -> 64 -> 255 -> 192
    check(menu_brightness == 8'd192, "C0 K1 x3 -> brightness back to 192");
    pv_a = active_index;
    press(0, 200); wait_ms(20);
    check(menu_contrast == 8'd192 && `HT == `T_H_CON3 && active_index == pv_a, "C0 K2 -> contrast 192, hint 对比度 3, no image switch");
    for (k = 0; k < 3; k = k + 1) press(0, 200);
    check(menu_contrast == 8'd128, "C0 K2 x3 more -> contrast cycles back to 128");
    k3_click; wait_ms(20);
    check(u_router.menu_sat == 2'd3 && pipe_sat == 2'd3 && `HT == {{7{8'h20}}, `T_D_COLOR, " ", `T_SAT3, {8{8'h20}}} &&
          `M2 == `M2D && `S3 == `S3L(`T_SAT3, `T_SC0, " 3"), "C0 K3 -> 色彩 鲜艳 reaches pipeline, hint + status row 3");
    k3_click; k3_click; k3_click; wait_ms(20);
    check(pipe_sat == 2'd2 && `HT == {{7{8'h20}}, `T_D_COLOR, " ", `T_SAT2, {8{8'h20}}}, "C0 K3 x3 more -> 鲜艳 -> 黑白 -> 淡 -> 标准");
    press(1, 200); wait_ms(20);
    check(u_router.sub_color == 3'd1 && cpr_active == 1'b0 && thumb_view == 1'b0 &&
          `HT == {{6{8'h20}}, `T_D_SCOL, " ", `T_SC1, {7{8'h20}}} && `S3 == `S3L(`T_SAT2, `T_SC1, " 3"),
          "C0 K4 click -> 字幕颜色 黄 (no CPR), hint + status row 3");
    for (k = 0; k < 7; k = k + 1) press(1, 200);
    check(u_router.sub_color == 3'd0, "C0 K4 x7 more -> colour back to 白");
    check(u_router.auto_int == 3'd1 && u_router.auto_lim == 3000 - 1, "C0 default 轮播间隔 3 秒 (index 1)");
    press(1, 1200); wait_ms(20);
    check(u_router.auto_int == 3'd2 && u_router.auto_lim == 5000 - 1 && thumb_view == 1'b0 &&
          `HT == {{5{8'h20}}, `T_D_INT, " ", " 5", " ", `T_D_SEC, {5{8'h20}}} && `S3 == `S3L(`T_SAT2, `T_SC0, " 5"),
          "C0 K4 hold -> 轮播间隔 5 秒 (no thumbnail), hint + status row 3");
    press(1, 1200); press(1, 1200); press(1, 1200); wait_ms(20);
    check(u_router.auto_int == 3'd5 && `S3 == `S3L(`T_SAT2, `T_SC0, "15"), "C0 K4 hold x3 -> 15 秒");
    press(1, 1200); wait_ms(20);
    check(u_router.auto_int == 3'd0 && u_router.auto_lim == 1000 - 1 && `S3 == `S3L(`T_SAT2, `T_SC0, " 1") &&
          `HT == {{5{8'h20}}, `T_D_INT, " ", " 1", " ", `T_D_SEC, {5{8'h20}}}, "C0 K4 hold -> 1 秒 (R8-2b)");
    press(1, 1200);
    check(u_router.auto_int == 3'd1 && u_router.auto_lim == 3000 - 1, "C0 K4 hold -> back to 3 秒");
    sw1 = 1'b0; wait_ms(40);
    check(menu_visible == 1'b0 && !u_router.menu_disp && `HT == `T_H_SET_OFF, "C0 SW1 off -> play mode again");
    wait_frames(2);
    // ---- R7b-2 急救：播放页全屏 K4 单击进入；① ② ③ PIC6 -> 交接（PIC6 压暗）-> 回到被打断的图 ----
    press(1, 1200);                                    // 缩略图里 K4 单击 = 确认，不进急救
    wait_frames(2);
    press(0, 200);                                     // 焦点先右移（3 -> 0）
    wait_frames(2);
    press(1, 200);
    wait_frames(3);
    check(cpr_active == 1'b0 && thumb_view == 1'b0, "C1 K4 click in thumbnail = confirm, no CPR");
    cpr_pic = active_index;
    press(1, 200);                                     // 全屏 K4 单击：开始急救
    wait_frames(4);
    check(cpr_active == 1'b1 && cpr_state == 3'd1 && cpr_timer_bcd == 16'd0 && cpr_mode_302, "C1 K4 click -> part 1 CALL, timer 00:00, default 30:2");
    check(active_index == cpr_pic && emg_ovr_en && last_frame_pic == EMG_PIC,
          HAS6 ? "C1 CALL overrides display with PIC6, player index unchanged, pixel-exact"
               : "C1 CALL without PIC6 -> black frames, player index unchanged");
    check(pipe_brightness == 8'd255 && pipe_contrast == 8'd128, "C1 CPR forces brightness 255 / contrast 128");
    check(pipe_no_transition == 1'b1 && menu_visible == 1'b1 && `M1 == `T_C_T1Za && `M2 == `T_C_T1Zb,
          "C1 hard cut; right box tips 确认周围环境安全 / 安全了再靠近患者");
    check(hint_show && !hint_leave && `HT == `T_H_C_1Z && `S1 == `S1C("00:00") && `S2 == `S2C("01", "0000") && `S3 == `T_C_K1,
          "C1 bottom ①这里有人晕倒了; status 晕倒已过 00:00 无语音 / 30:2 第01组 按压0000次 / K3开始按压 长按K4取消");
    check(u_router.cpr_part == 2'd1 && !u_router.note_show, "C1 progress frame on column 1, no centre note");
    wait_ms(4000);
    check(`HT == `T_H_C_1A && `M1 == `T_C_T1Aa, "C1 at 4 s: ②拍双肩 大声喊, tips 双手拍他双肩");
    wait_ms(2000);
    check(`HT == `HLOOK(" ") && `M1 == `T_C_T1Ba, "C1 at 6 s: ③看胸口起伏 (no digit yet), tips 看胸口5~10秒");
    wait_ms(3000);
    check(`HT == `HLOOK("3"), "C1 at 9 s: countdown 3 (5 at 7 s ... 1 at 11 s)");
    nk0 = n_key;
    k1_click;                                          // K1 单击 = 重播第一部分（时间轴从头）
    wait_ms(20);
    check(auto_run == 1'b0 && u_router.auto_on == 1'b0 && u_router.u_cpr.step_sec == 7'd0 && `HT == `T_H_C_1Z,
          "C1 K1 click in CPR -> replay part 1 (timeline restarts), autoplay untouched");
    press(0, 200);
    check(cpr_mode_302 == 1'b1, "C1 K2 in part 1 ignored (mode stays 30:2)");
    check(n_key == nk0 + 2, "K1 key click sound on every key press, even when the key does nothing (K1, K2)");
    nk0 = n_key;
    press(1, 2100);                                    // ① K4 长按 2 秒 = 误触取消
    check(cpr_state == 3'd0 && cpr_active == 1'b0, "C1b K4 2s hold in step 1 -> cancelled, straight back to standby (no SUMMARY)");
    check(n_key == nk0 + 3, "K2 K4 2 s hold: click on press, at 1 s and when the 2 s hold takes effect");
    wait_frames(4);
    check(!emg_ovr_en && active_index == cpr_pic && last_frame_pic == pic_of_bank(cpr_pic) && thumb_view == 1'b0,
          "C1b cancel -> back to the interrupted image, pixel-exact");

    press(1, 200);                                     // 再进一次
    check(cpr_state == 3'd1, "C2 K4 click -> part 1 again");
    nb0 = n_beat;
    k3_click;                                          // K3：跳过第一部分 -> ② 心肺复苏
    wait_frames(3);
    check(cpr_state == 3'd2 && last_frame_pic == EMG_PIC && active_index == cpr_pic && u_router.cpr_part == 2'd2,
          HAS6 ? "C2 K3 -> part 2 CPR, PIC6 (bank5) pixel-exact, frame column 2" : "C2 K3 -> part 2 CPR, no PIC6 -> black");
    check(`M1 == `T_C_T2Ia && `M2 == `T_C_T2Ib && `HT == `T_H_C_2I && `S3 == `T_C_K2,
          "C2 first entry: ①按压 两乳头中间, tips 两乳头连线中点 / 双手交叠 掌根用力, keys AED到按K3");
    check(menu_brightness == 8'd192, "C2 K3 in CPR does not touch brightness menu");
    wait_ms(8000);
    check(n_beat == nb0, "C2 first entry: 8 s into the 10 s preparation, no beat yet");
    wait (u_router.u_cpr.step_sec == 7'd9); wait_ms(30);
    check(n_beat == nb0 && `HT == `T_H_C_2S && `M1 == `T_C_T2Ia, "C2 9 s: ①开始按压, still no beat");
    @(posedge cpr_beat); @(posedge sd_clk);
    nb0 = n_beat;  nbp0 = n_beep;
    wait_ms(5454);                                     // 10 个节拍周期（110 次/分 = 545.4ms）
    check(n_beat - nb0 == 10, "C2 metronome 110/min: 10 beats in 5.454 s");
    k = n_beat - nb0;
    wait_ms(1);                                        // 声音比 cpr_beat 晚几拍（过域 + 等 48 kHz 节拍）
    check(n_beep - nbp0 == k, "C2 metronome sound: one beep per beat (cpr_beat -> cue_tone_gen)");
    check(u_router.cpr_comp_bcd == bcd4(n_beat), "C2 compression count (BCD) = beats");
    @(posedge cpr_beat); wait_ms(20);                  // 刚打完一拍，文字已刷新
    check(`S2 == `S2C("01", asc4(bcd4(n_beat))) && `S1 == `S1C(mmss(txt_ctmr)) &&
          `HT == `HPRESS(cyc2(u_router.cpr_cyc)) && `M1 == `T_C_T2Ca, "C2 status 30:2 第01组 按压nnnn次, bottom ①胸外按压 nn/30, tips 深5~6厘米");
    @(posedge cpr_beat); @(posedge sd_clk);
    u_router.u_cpr.cyc = 5'd29;                        // 跳到本组第 29 下
    @(posedge cpr_beat); @(posedge sd_clk);
    check(u_router.cpr_cyc == 5'd30 && !cpr_breath, "C3 30th compression");
    nb0 = n_beat;
    wait_ms(600);                                      // 第 31 拍的位置（+545ms）：人工呼吸 10 秒（R11）
    check(cpr_breath == 1'b1 && n_beat == nb0 && u_router.u_cpr.br_sec == 4'd0, "C3 after 30 compressions -> rescue breaths, no beat");
    nbp0 = n_beep;
    wait_ms(30);                                       // 人工呼吸 +85ms
    check(`HT == `HBR("1") && `M1 == `T_C_TBRa && `M2 == `T_C_TBRb, "C3 bottom ③人工呼吸 1/2, tips 捏鼻包嘴 / 每口1秒 看胸口起");
    wait_ms(4415);                                     // +4.5 s
    check(cpr_breath == 1'b1 && n_beat == nb0 && `HT == `HBR("1") && u_router.cpr_led == 4'h0 && !u_router.cpr_blow, "C3 at 4.5 s: still 1/2, LED off, no blow tone");
    wait_ms(1000);                                     // +5.5 s：第 1 口
    check(u_router.cpr_led == 4'hf && u_router.cpr_blow && u_cue.b_on, "C3 at 5.5 s: first breath, 4 LEDs on, blow tone on (R12d cpr_blow)");
    wait_ms(600);                                      // +6.1 s
    check(cpr_breath == 1'b1 && n_beat == nb0 && `HT == `HBR("2") && u_router.cpr_led == 4'h0 && !u_router.cpr_blow, "C3 at 6.1 s: 第二次吹气 2/2, LED off, blow tone off");
    wait_ms(2000);                                     // +8.1 s
    check(cpr_breath == 1'b1 && `HT == `T_H_C_BE, "C3 at 8.1 s: ①继续准备按压");
    check(n_beep == nbp0, "C3 no metronome sound during rescue breaths");
    wait_ms(2000);                                     // +10.1 s
    check(cpr_breath == 1'b0 && n_beat == nb0 + 1 && u_router.cpr_cyc == 5'd1 && u_router.cpr_grp == 8'h02,
          "C3 10 s rescue breaths over -> group 02, compression 1/30");
    wait_ms(50);
    check(`S2 == `S2C("02", asc4(u_router.cpr_comp_bcd)), "C3 status 30:2 第02组");
    u_router.u_cpr.timer_bcd = 16'h0159;               // R12：「晕倒已过」到 02:00 立即提示换人（不等人工呼吸）
    check(!u_router.cpr_swap && !u_router.note_show, "C3b 01:59 no swap hint");
    wait (u_router.cpr_timer_bcd == 16'h0200);
    wait_ms(20);
    check(!cpr_breath && u_router.cpr_swap && u_router.note_show && `FT == `T_F_NSW && `M1 == `T_C_TSWa,
          "C3b 02:00 -> centre note 到了两分钟，建议换人 at once, tips 换人别停超10秒");
    wait_ms(10000);
    check(!u_router.cpr_swap && !u_router.note_show, "C3b swap hint off after 10 s");
    press(0, 200);                                     // K2 单击：单纯按压（R10 7A 暂缓，K2 仍是单击切模式）
    wait_ms(20);
    check(cpr_mode_302 == 1'b0 && `S2 == `S2P(asc4(u_router.cpr_comp_bcd)), "C3c K2 -> 单纯按压, status 单纯按压 按压nnnn次");
    u_router.u_cpr.cyc = 5'd29;
    @(posedge cpr_beat); @(posedge cpr_beat); @(posedge sd_clk);
    check(!cpr_breath && u_router.cpr_cyc == 5'd1, "C3c 单纯按压: no rescue breaths, count wraps 30 -> 1");
    press(0, 200);
    check(cpr_mode_302 == 1'b1, "C3c K2 again -> 30:2");
    // R10 7B：每拍 LED 全亮 100 ms
    @(posedge cpr_beat); wait_ms(50);
    check(u_router.cpr_led == 4'hf && !u_router.cpr_blow, "C3e LED: all 4 on right after a beat, but no blow tone (R12d)");
    check(n_blow_cpr == 0, "C3e blow tone never on during compressions (R12a bug: tied to the beat LED)");
    wait_ms(100);
    check(u_router.cpr_led == 4'h0 || cpr_breath, "C3e LED: off 100 ms after the beat");

    k3_click;                                          // K3：AED 到了 -> ③
    wait_frames(2);
    k = cpr_aed_time_bcd;
    check(cpr_state == 3'd3 && u_router.cpr_aed_seen && last_frame_pic == EMG_PIC && u_router.cpr_part == 2'd3,
          "C4 K3 -> part 3 AED, arrival recorded, still emergency image, frame column 3");
    wait_ms(20);
    check(`M1 == `T_C_T3Aa && `HT == `T_H_C_3A && `S3 == `T_C_K3, "C4 bottom AED优先 照图做, tips 开机 跟语音做, keys 要按压时按K3");
    nb0 = n_beat;
    wait_ms(5500);
    check(n_beat == nb0 && `HT == `T_H_C_3B && `M1 == `T_C_T3Ba, "C4 no beats in part 3; after 5 s 听AED语音 别碰患者");
    k3_click;                                          // K3：AED 说继续 CPR -> ②，R10：先准备 3 秒再从「一」数起
    wait_ms(30);
    check(cpr_state == 3'd2 && n_beat == nb0 && u_router.cpr_cyc == 5'd0 && `HT == `T_H_C_2R && `M1 == `T_C_T2Ra,
          "C5 K3 -> back to part 2, ①继续按压, 3 s preparation (no beat yet)");
    wait_ms(3200);
    check(u_router.cpr_cyc >= 5'd1 && u_router.cpr_cyc <= 5'd3 && `HT == `HPRESS(cyc2(u_router.cpr_cyc)),
          "C5 after 3 s counting restarts from 1 (prep ends on the 3rd second tick = 2~3 s, so 1~3 beats by now), bottom shows the count");
    k1_click; wait_ms(20);                             // K1：重讲按压要领（R10：同样准备 3 秒，从「一」重新数）
    k = n_beat; wait_ms(1200);
    check(`HT == `T_H_C_2I && n_beat == k && u_router.cpr_cyc == 5'd0, "C5 K1 replay in part 2 -> ①按压 两乳头中间 again, no beats while explaining");
    k = cpr_aed_time_bcd;
    k3_click; wait_ms(20);
    check(cpr_state == 3'd3 && cpr_aed_time_bcd == k, "C6 K3 -> part 3 again, first AED time kept");
    check(last_frame_pic == EMG_PIC && active_index == cpr_pic, "C6 part 3 keeps emergency image");
    press(1, 1200);                                    // K4 长按 1 秒：急救中无效
    check(cpr_state == 3'd3 && thumb_view == 1'b0, "C6 K4 1s hold during CPR ignored");
    press(1, 200);
    check(cpr_state == 3'd3, "C6 K4 click during CPR ignored");
    press(1, 2100);                                    // K4 长按 2 秒：结束 -> 交接
    check(cpr_state == 3'd4 && u_router.cpr_part == 2'd0, "C7 K4 2s hold -> SUMMARY, no progress frame");
    k = cpr_timer_bcd;  nb0 = n_beat;
    wait_ms(1500);
    check(cpr_timer_bcd == k && n_beat == nb0, "C7 timer / count frozen in SUMMARY");
    check(`S1 == {`T_C_END, {16{8'h20}}} && `S2 == {`T_C_PAST, " ", mmss(k), {10{8'h20}}}, "C7 left 急救结束 / 晕倒已过 mm:ss");
    check(`M1 == {`T_C_BEATS, " ", asc4(u_router.cpr_comp_bcd), " ", `T_C_TIMES, {8{8'h20}}} &&
          `M2 == {`T_C_AED1, " ", mmss(cpr_aed_time_bcd), " ", `T_C_AED2, {7{8'h20}}} && `HT == `T_H_C_END && `S3 == `T_C_KE,
          "C7 right 按压节拍 nnnn 次 / AED 第 mm:ss 送到, bottom 请向 120 医生交接, keys 长按K4 回到广告");
    check(pipe_brightness == 8'd64 && emg_ovr_en && emg_ovr_bank == 3'd5, "C7 SUMMARY shows PIC6 dimmed to 1/4");
    press(1, 200);
    check(cpr_state == 3'd4, "C8 K4 click in SUMMARY ignored");
    press(1, 2100);                                    // K4 长按 2 秒：回广告
    check(cpr_state == 3'd0 && cpr_active == 1'b0 && thumb_view == 1'b0, "C8 K4 2s hold in SUMMARY -> STANDBY (no thumbnail)");
    wait_ms(20);
    check(pipe_brightness == 8'd192 && !hint_show && `S1[191:160] == `T_S_AUTO, "C8 standby brightness / status bar restored");
    wait_frames(4);
    check(emg_ovr_en == 1'b0 && active_index == cpr_pic && last_frame_pic == pic_of_bank(cpr_pic),
          "C8 override removed -> back to the interrupted image, pixel-exact");
    press(1, 200);                                     // 再来一次：呼救 15 秒超时自动进 ②
    check(cpr_state == 3'd1 && cpr_timer_bcd == 16'd0 && u_router.cpr_comp_bcd == 16'd0 && cpr_mode_302 && !u_router.cpr_aed_seen &&
          u_router.cpr_grp == 8'h01, "C9 new emergency resets timer / count / group / AED, mode back to 30:2");
    wait_ms(13000);
    check(cpr_state == 3'd1 && `HT == `T_H_C_1C && `M1 == `T_C_T1Ca, "C9 at 13 s: ④打120 取AED, tips 开免提跟120说");
    wait_ms(5000);
    check(cpr_state == 3'd1 && `HT == `T_H_C_1D && `M1 == `T_C_T1Da && !u_router.note_show, "C9 at 18 s: 下面进行CPR按压+人工呼吸, tips 让患者平躺硬地上");
    wait_ms(3000);
    check(cpr_state == 3'd1 && u_router.note_show && `FT == `T_F_NK3, "C9 at 21 s: centre note 准备好后按K3开始按压");
    wait_ms(10000);
    check(cpr_state == 3'd1 && u_router.note_show, "C9 still part 1 at 31 s (no timeout any more)");
    k3_click; wait_ms(20);
    check(cpr_state == 3'd2 && !u_router.note_show && `HT == `T_H_C_2I, "C9 K3 -> part 2, centre note gone");
    press(1, 2100);
    wait_ms(20);
    check(cpr_state == 3'd4 && `M2 == `T_C_NOAED, "C9 SUMMARY without AED -> AED 未送到");
    press(1, 2100);
    check(cpr_state == 3'd0, "C9 back to standby");
    check(reader_underflow == 1'b0 && video_error == 8'd0, "C10 no underflow / reader error through CPR flow");

    // ---- R1：拨码功能页 + 菜单 ----
    // 规范 v2：SW1 关时 SW2/SW3 不起作用，只提示
    k = active_index;
    wait_ms(2100);
    sw2 = 1'b1; wait_ms(40);
    check(ui_page == 2'd0 && menu_visible == 1'b0 && hint_show && `HT == `T_H_SW1,
          "M0 SW1 off + SW2 on -> page stays 00, hint TURN ON SW1 FIRST");
    press(0, 200); wait_frames(3);
    check(active_index == (k + 1) % n_img, "M0 SW1 off: K2 click still switches image");
    press(0, 1200); wait_frames(3);
    check(active_index == k, "M0 SW1 off: K2 hold -> back");
    wait_ms(2100);
    check(!hint_show && !hint_leave, "M0 hint gone after 1.25s");
    sw2 = 1'b0; wait_ms(40);
    sw1 = 1'b1; wait_ms(40);                           // SW1 开，页 00：提示 SETUP ON
    check(ui_page == 2'd0 && hint_show && `HT == `T_H_SET_ON && menu_visible == 1'b1 && `M1 == `M1D && `M2 == `M2D,
          "M0 SW1 on at page 00 -> hint 设置模式 开启, menu box = display page key table");
    sw2 = 1'b1; wait_ms(40);                           // page 01 TRANS
    check(ui_page == 2'd1 && menu_visible == 1'b1, "M1 SW2 on -> page 01, menu visible");
    wait_ms(20);
    show_menu;
    check(`M1 == {`T_M_SETUP, `T_PG_TRANS, "    ", "  1/3"} && `M2 == {`T_I_EFFECT, "00 ", `T_E00}, "M1 menu 设置:转场 1/3 / 效果 00 淡入淡出");
    check(`HT == `T_H_TRANS, "M1 hint 转场设置");
    press(0, 200);                                     // K2 单击：下一项 SPEED（不切图）
    wait_ms(20);
    check(`M2 == {`T_I_SPEED, "3", {14{8'h20}}} && active_index == k, "M2 K2 click -> 速度 3, image unchanged");
    k3_click;                                          // K3：3 -> 4
    wait_ms(20);
    check(u_router.u_menu.fx_speed == 4'd4 && `M2 == {`T_I_SPEED, "4", {14{8'h20}}}, "M3 K3 click -> 速度 4");
    check(menu_brightness == 8'd192, "M3 K3 in menu page does not touch brightness");
    press(1, 200); press(1, 200); press(1, 200);       // K4 x3：4 -> 1
    check(u_router.u_menu.fx_speed == 4'd1, "M4 K4 x3 -> speed 1");
    press(1, 200);                                     // R11：到 1 再减回 8
    check(u_router.u_menu.fx_speed == 4'd8, "M4 K4 at 1 -> wraps to 8 (R11)");
    k3_click;                                          // 到 8 再加回 1
    check(u_router.u_menu.fx_speed == 4'd1, "M4 K3 at 8 -> wraps to 1 (R11)");
    key_auto = 1'b0; wait_ms(1000); key_auto = 1'b1; wait_ms(100);   // K4 按住 1 秒：连续减（循环）
    check(u_router.u_menu.fx_speed != 4'd1 && u_router.u_menu.fx_speed <= 4'd8, "M4 K4 hold -> repeat down with wrap");
    check(thumb_view == 1'b0, "M4 K4 hold in menu page does not enter thumbnail");
    press(0, 1200);                                    // K2 长按：上一项 EFFECT
    wait_ms(20);
    k3_click; k3_click; k3_click; k3_click; k3_click; k3_click; k3_click;
    wait_ms(20);
    show_menu;
    check(`M2 == {`T_I_EFFECT, "07 ", `T_E07}, "M5 K2 hold -> 效果, K3 x7 -> 07 菱形");
    pv_a = active_index;  pv_auto = u_router.auto_on;    // R8-2：转场页 K1 = 预览（不再是轮播开关）
    pv_seen = 1'b0;
    k1_click;
    wait_frames(2);
    pv_n = 0;
    while (pipe_transition_busy && pv_n < 400) begin wait_frames(1); pv_n = pv_n + 1; end
    check(pv_seen && active_index == pv_a && u_router.auto_on == pv_auto && `M1 == {`T_M_SETUP, `T_PG_TRANS, "    ", "  1/3"},
          "M5b TRANS page K1 click -> preview request, image not switched (R8-2b), autoplay not toggled");
    sw3 = 1'b1; wait_ms(40);                           // page 11 VIEW
    wait_ms(20);
    check(ui_page == 2'd3 && `M1 == {`T_M_SETUP, `T_PG_VIEW, "    ", "  1/9"} && `M2 == {`T_I_SX, "1.00 ", `T_U_TIMES, "        "}, "M6 page 11 画面与声音 / 横向缩放 1.00 倍");
    for (x = 0; x < 7; x = x + 1) press(0, 200);       // 下一项 x7 -> VOLUME（R8-4b 删推拉摇移）
    wait_ms(20);
    show_menu;
    check(`M1 == {`T_M_SETUP, `T_PG_VIEW, "    ", "  8/9"} && `M2 == {`T_I_VOL, " 60%", {11{8'h20}}}, "M7 item 8 音量 60%");
    k3_click; k3_click;
    check(u_router.u_menu.vw_volume == 4'd8 && menu_vol_gain == 8'd204, "M7 VOLUME 80% -> gain 204");
    sw2 = 1'b0; wait_ms(40);                           // page 10 LAYER
    wait_ms(20);
    show_menu;
    check(ui_page == 2'd2 && `M1 == {`T_M_SETUP, `T_PG_LAYER, `T_L_LOGO, "   ", "  1/8"}, "M8 page 10 图层-台标");
    press(0, 200); press(0, 200);                      // -> X
    k3_click;
    wait_ms(20);
    check(`M2 == {`T_I_X, "536", {12{8'h20}}}, "M8 台标 横坐标 528 -> 536");
    sw3 = 1'b0; wait_ms(40);                           // 回 page 00
    check(ui_page == 2'd0 && menu_visible == 1'b1 && hint_show && `HT == `T_H_PLAY && `M1 == `M1D && u_router.menu_disp, "M9 back to page 00 (SW1 on): display page, hint 显示设置");
    wait_ms(2100);
    check(!hint_show && !hint_leave, "M9 hint gone");
    k = active_index;
    press(0, 200);
    wait_frames(3);
    check(active_index == k && menu_contrast == 8'd192, "M9 display page K2 click -> contrast, no image switch");
    press(0, 200); press(0, 200); press(0, 200);
    check(menu_contrast == 8'd128, "M9 contrast back to 128");
    sw2 = 1'b1; wait_ms(40);
    sw1 = 1'b0; wait_ms(40);                           // 在菜单页拨 SW1 关：回播放页，提示 SETUP OFF
    check(ui_page == 2'd0 && menu_visible == 1'b0 && hint_show && `HT == `T_H_SET_OFF, "M9 SW1 off in menu page -> page 00, hint 设置模式 关闭");
    sw1 = 1'b1; wait_ms(40);
    check(ui_page == 2'd1 && menu_visible && `M1 == {`T_M_SETUP, `T_PG_TRANS, "    ", "  1/3"} && `HT == `T_H_SET_ON, "M9 SW1 on again with SW2 up -> TRANS menu + hint 设置模式 开启");
    press(1, 200);                                     // 菜单页 K4 单击 = 减一档，不进急救
    wait_ms(20);
    check(cpr_active == 1'b0 && `M2 == {`T_I_EFFECT, "06 ", `T_E06}, "M10 K4 click in menu page -> 效果 06, no CPR");
    k3_click;
    sw2 = 1'b0; wait_ms(40);
    wait_ms(2100);
    press(1, 200);                                     // R8-2：显示页 K4 单击 = 字幕颜色，不进急救
    wait_ms(20);
    check(cpr_active == 1'b0 && u_router.sub_color == 3'd1 && `M2 == `M2D && `S3 == `S3L(`T_SAT2, `T_SC1, " 3"),
          "M10 display page K4 click -> 字幕颜色 黄, no CPR");
    for (x = 0; x < 7; x = x + 1) press(1, 200);
    check(cpr_active == 1'b0 && u_router.sub_color == 3'd0 && menu_visible && u_router.u_menu.fx_effect == 4'd7,
          "M10 K4 x7 more -> back to 白, effect 07 kept");
    sw1 = 1'b0; wait_ms(40);                           // 后面的测试都在播放模式
    check(reader_underflow == 1'b0 && video_error == 8'd0, "M11 no underflow / reader error through menu tests");

    // ---- R4：显示中拔卡 / 插回 ----
    check(fault_code == 4'd0, "R2 start-up warning gone after 5s");
    k = active_index;
    x = n_wr;
    card_in = 1'b0;                                    // 拔卡：空闲探测 1s 内读一次扇区，读 0.3s 不结束 -> 判定丢卡
    wait_ms(1600);
    check(tf_lost == 1'b1 && fault_code == 4'd4 && display_valid == 1'b1, "R2 card pulled while displaying: fault 4 (TF read failed), display stays on");
    press(0, 200); wait_frames(3);
    check(active_index == (k + 1) % n_img && last_frame_pic == pic_of_bank((k + 1) % n_img), "R2 K2 still switches images (all in SDRAM)");
    wait_ms(2000);
    check(tf_lost == 1'b1 && fault_code == 4'd4, "R2 still lost while card is out (init watchdog keeps retrying)");
    card_in = 1'b1;
    wait_ms(1000);
    check(tf_lost == 1'b0 && fault_code == 4'd0 && `HT == `T_H_TFOK, "R3 card back: recovered automatically, hint TF card recovered");
    check(n_wr == x && dut.ig_state == 3'd5 && display_valid, "R3 no image reload / SDRAM write during hot recovery");
    press(0, 200); wait_frames(3);
    check(active_index == (k + 2) % n_img && last_frame_pic == pic_of_bank((k + 2) % n_img), "R3 K2 switch after recovery pixel-exact");
    check(reader_underflow == 1'b0 && video_error == 8'd0, "R3 no underflow / reader error through unplug / replug");

    // ---- R5：画面变换（直接改 VIEW 页参数寄存器；菜单按键路径 M6/M7 已测过）----
    geo_set(1, 0, 4, 4, 0, 0);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G1 mirror: frames pixel-exact (left-right swapped)");
    geo_set(1, 1, 4, 4, 0, 0);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G2 mirror + flip = rotate 180: pixel-exact");
    geo_set(0, 0, 8, 4, 0, 0);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G3 scale-x 2.00 about centre: pixel-exact");
    geo_set(0, 0, 8, 2, 0, 0);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G4 scale-y 0.50 (black bands top / bottom): pixel-exact");
    geo_set(0, 0, 4, 4, 1, 1);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G5 pan +16 / +16 (black on right / bottom): pixel-exact");
    geo_set(1, 0, 3, 6, -1, 0);
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G5 combined: mirror + scale 0.75 x 1.50 + pan -16: pixel-exact");
    k_pic = active_index;
    press(0, 200); wait_frames(4); k = good_frames; wait_frames(3);
    check(active_index == (k_pic + 1) % n_img && good_frames >= k + 2 && errors == 0, "G6 K2 switch with transform: next image pixel-exact");
    press(1, 1200); wait_frames(4);
    check(thumb_view == 1'b1, "G7 thumbnail entered (transform forced off in thumbnail)");
    k = thumb_frames; wait_frames(3);
    check(thumb_frames >= k + 2 && errors == 0, "G7 thumbnail frames pixel-exact");
    geo_chg = 1'b1;  frame_checked = 1'b0;
    press(1, 1200); wait_frames(3);
    geo_chg = 1'b0;
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G7 back to fullscreen: transform applies again");
    geo_set(0, 0, 4, 4, 0, 0);
    geo_on = 1'b0;
    k = good_frames; wait_frames(3);
    check(good_frames >= k + 2 && errors == 0, "G8 identity again: pixel-exact");
    check(reader_underflow == 1'b0 && video_error == 8'd0, "G9 no underflow / reader error through transforms");

    // R10 资源：一键演示删掉（原 D0~D4 用例）
`else
    // ---- R12c 推移转场：向左 / 向上推移，K2 下一张，转场中每一帧都是「旧图一段 + 新图一段」逐像素正确，一帧不黑 ----
    for (k = 14; k <= 15; k = k + 1) begin
        u_router.u_menu.fx_effect = k;
        wait_frames(2);
        k_pic = active_index;  pk0 = push_frames;  pk1 = push_err;
        press(0, 200);
        wait_frames(30);
        $sformat(pname, "P%0d effect %0d (%0s push): %0d push frames pixel-exact, ends on the next image", k - 13, k,
                 (k == 14) ? "left" : "up", push_frames - pk0);
        check(active_index == (k_pic + 1) % n_img && push_frames >= pk0 + 8 && push_err == pk1 &&
              last_frame_pic == pic_of_bank(active_index) && pipe_transition_busy == 1'b0, pname);
    end
    u_router.u_menu.fx_effect = 4'd1;
    wait_frames(2);
    // ---- FADE16：真实转场参数下，急救必须硬切（急救中每一帧都整帧精确，没有淡入 / Wipe）----
    k1_click;                                          // 待机自动轮播（K1 单击，Wipe 揭示）
    check(auto_run == 1'b1, "F0 K1 click -> autoplay");
    wait_ms(2800);                                     // 3s 轮播周期：K4 松开时正好在转场附近
    press(1, 200);
    check(cpr_active == 1'b1 && auto_run == 1'b0, "F1 K4 click -> CPR, autoplay forced off");
    wait_frames(4);
    check(last_frame_pic == EMG_PIC, "F1 CALL shows PIC6 pixel-exact (hard cut)");
    check(pipe_transition_busy == 1'b0, "F1 transition engine back to idle within 4 frames");
    k3_click; wait_frames(3);
    k3_click; wait_frames(3);
    k3_click; wait_frames(3);
    check(cpr_state == 3'd2 && last_frame_pic == EMG_PIC, "F2 part 1 -> 2 -> 3 -> 2, PIC6");
    check(good_frames >= 10, "F2 every CPR frame pixel-exact (no fade / wipe)");
    press(1, 2100); press(1, 2100);
    check(cpr_state == 3'd0 && auto_run == 1'b1, "F3 back to standby, autoplay resumes");
    wait_ms(3500); wait_frames(3);
    check(last_frame_pic == pic_of_bank(active_index), "F3 autoplay after CPR shows a full image (no black screen)");
    check(reader_underflow == 1'b0 && video_error == 8'd0, "F4 no underflow / reader error");
`endif
    $display("  缩略图好帧 %0d 个", thumb_frames);
    $display("  好帧 %0d 个", good_frames);

    $display("------------------------------------------------");
    $display("RESULT: %0s（%0d 个失败）", (errors == 0) ? "PASS" : "FAIL", errors);
    $finish;
end

initial begin
    #(300_000_000);                                    // R11：急救流程变长（① 等 K3、② 准备 10 秒、人工呼吸 10 秒）
    $display("RESULT: FAIL（超时） display_valid=%0d ig_state=%0d", display_valid, dut.ig_state);
    $finish;
end

endmodule

// ---------------- rfifo_32_32_512 行为模型（替换 TD 生成的 IP）----------------
module rfifo_32_32_512 #(
    parameter DATA_WIDTH_W = 32, parameter DATA_WIDTH_R = 32,
    parameter ADDR_WIDTH_W = 9,  parameter ADDR_WIDTH_R = 9,
    parameter AL_FULL_NUM = 509, parameter AL_EMPTY_NUM = 2,
    parameter SHOW_AHEAD_EN = 1'b0, parameter OUTREG_EN = "NOREG"
) (
    input rst, input clkw, input clkr, input we, input [DATA_WIDTH_W-1:0] di,
    input re, output reg [DATA_WIDTH_R-1:0] dout, output reg valid,
    output full_flag, output empty_flag, output afull, output aempty,
    output [ADDR_WIDTH_W-1:0] wrusedw, output [ADDR_WIDTH_R-1:0] rdusedw
);
    reg [DATA_WIDTH_W-1:0] mem [0:(1<<ADDR_WIDTH_W)-1];
    reg [ADDR_WIDTH_W:0] wp = 0, rp = 0;
    wire [ADDR_WIDTH_W:0] used = wp - rp;
    assign full_flag  = used >= (1 << ADDR_WIDTH_W) - 1;
    assign empty_flag = used == 0;
    assign afull      = used >= AL_FULL_NUM;
    assign aempty     = used <= AL_EMPTY_NUM;
    assign wrusedw    = used[ADDR_WIDTH_W-1:0];
    assign rdusedw    = used[ADDR_WIDTH_R-1:0];
    always @(posedge clkw or posedge rst)
        if (rst) wp <= 0;
        else if (we && !full_flag) begin mem[wp[ADDR_WIDTH_W-1:0]] <= di; wp <= wp + 1'b1; end
    always @(posedge clkr or posedge rst)
        if (rst) begin rp <= 0; valid <= 1'b0; end
        else begin
            valid <= re && !empty_flag;
            if (re && !empty_flag) begin dout <= mem[rp[ADDR_WIDTH_R-1:0]]; rp <= rp + 1'b1; end
        end
endmodule
