
module top(
    input                       clk,
    input                       key0,           // R7a：K1（A2）单击 = 自动轮播 开/关（原来是复位键，改为内部上电复位）
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,           // R8-2：播放模式单击 = 字幕开 / 关，显示页 = 色彩（按住期间数码管仍显示诊断页）
    input                       sw1,            // 规范 v2：拨码 SW1（C8）开 = 设置模式
    input                       sw2,            // R1 功能页：拨码 SW2（C7）= 页号低位
    input                       sw3,            // R1 功能页：拨码 SW3（C6）= 页号高位
    input                       sw4,            // 规范 v2：拨码 SW4（C5）开 = 背景音乐（R7a：急救入口改为 K4 单击）

	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // R8-1c 板载 CH340 串口（电脑换字幕）
    input                       uart_rx,
    output                      uart_tx,

    // R10 板上 4 个绿色 LED（A4 / A3 / C10 / B12，高电平亮）：急救按压节拍灯
    output [3:0]                led
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 307200;       // 640*480，每张图占一个 bank

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data;
wire        display_valid;     // 第8课：四张图加载完才打开显示（sd_card_clk 域）

wire [3:0]  state_code;
wire [3:0]  disp_img_no;       // 当前显示第几张（1~5），0=还没出图
wire        auto_play_on;
wire        img_loading;
wire [11:0] last_load_time;    // 上一次加载耗时，BCD，单位 10ms
wire        last_load_err;     // 上一次加载超时
wire [3:0]  abort_code;        // 超时时卡在哪
wire [1:0]  abort_sd_stage;    // 超时时 SD 命令层阶段
wire [7:0]  crc_err_cnt;       // 扇区 CRC16 错误累计
wire [7:0]  fs_error;          // 第6课：FAT32 卷扫描错误码
wire [7:0]  rd_retry_cnt;      // 读扇区重试累计
wire [7:0]  crc_fail_cnt;      // 扇区重放：重读也救不回来的扇区数

// 第8课：四 bank 帧缓存（loader 写 / reader 读 / media_player_control 切图）
wire [2:0]  img_found_count;
wire        tf_sd_ready, tf_boot_done, tf_lost, tf_recovered;   // R4：故障提示 / 拔卡恢复
wire [5:0]  tf_found_mask, tf_giveup_mask;   // R8-1a：bit5 = PIC6（急救图，bank5）
wire        emg_ok;                          // R8-1a：PIC6 已加载
wire        emg_ovr_en, emg_ovr_black;       // R7b-1 急救覆盖（ui_key_router -> media_video_pipeline）
wire [2:0]  emg_ovr_bank;
wire [3:0]  fault_code;
wire [2:0]  fault_arg;
wire [2:0]  fault_tot;          // R12：开机读图提示总张数
reg  [16:0] ms_div_sd;          // R12b：sd_card_clk 域共用的 1ms 节拍（在 u_sdcard_reset 后面）
reg         ms_tick_sd;
wire        fault_show;
wire        loader_load_start;
wire [2:0]  loader_image_index;
wire        loader_pixel_valid;
wire [23:0] loader_pixel_rgb;
wire        loader_pixel_ready;
wire        loader_top_down;
wire        loader_frame_commit;
wire [7:0]  loader_decode_error;
wire        loader_load_busy;
wire        loader_load_done;
wire [4:0]  loader_image_complete;
wire [7:0]  loader_memory_error;
wire        loader_app_wr_en;
wire [20:0] loader_app_wr_addr;
wire [3:0]  loader_app_wr_mask;
wire [31:0] loader_app_wr_data;
wire        cdc_clear;
wire        cdc_idle_mem;
wire        cdc_idle_sd;
wire        cdc_src_rst_n;
wire        cdc_dst_rst_n;
wire        cdc_overflow;
wire [2:0]  active_index;      // video_clk 域：当前显示哪个 bank（0~4）
wire        auto_enabled;
wire        reader_underflow;
wire [7:0]  video_error;
wire        player_enable_mem;

// 第13课：K3 亮度 / 对比度档位（R8-0a 起在 ui_key_router 里，bc_menu_controller 删除）
wire [7:0]  menu_brightness;
wire [7:0]  menu_contrast;

// ===================== 第14课：缩略图交互（文档 3.2 / 4.2） =====================
// 按键（文档方案 C 的变体，4 个键都已有全屏功能，所以按模式复用）：
//   全屏：K2 单击 下一张 | K4 单击 轮播 / 长按 上一张 | K3 单击 亮度 / 长按 对比度 | K2 长按 进入缩略图
//   缩略图：K2 单击 焦点右移 | K4 单击 焦点左移 | K3 单击 确认（全屏显示该图）| K2 长按 返回全屏
wire        thumb_view;
wire [2:0]  thumb_focus;

// 像素域 frame_start -> sd_card_clk 单拍（toggle + 同步）
reg        fs_tgl_pix;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        fs_tgl_pix <= 1'b0;
    else if (pix_frame_start)
        fs_tgl_pix <= ~fs_tgl_pix;
end
reg [2:0]  fs_tgl_sd;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n)
        fs_tgl_sd <= 3'b000;
    else
        fs_tgl_sd <= {fs_tgl_sd[1:0], fs_tgl_pix};
end
wire ctrl_frame_start = fs_tgl_sd[2] ^ fs_tgl_sd[1];

thumbnail_controller u_thumbnail_controller (
    .clk            (sd_card_clk),
    .rst_n          (sdcard_rst_n),
    .key_right      (thumb_key_right),
    .key_left       (thumb_key_left),
    .key_confirm    (thumb_key_confirm),
    .key_mode       (thumb_key_mode),
    .image_complete (loader_image_complete),
    .frame_start    (ctrl_frame_start),
    .view_mode      (thumb_view),
    .focus_index    (thumb_focus),
    .active_index   (),                 // 快速选择改走 media_player_control（文档 3.3 钩子2：帧边界原子提交）
    .transition_req ()                  // 选中后的转场：player_control 提交新图时转场模块自动做 Wipe 揭示
);

// ===================== CPR 场景第 1 轮：按键 / 拨码路由 + 急救流程状态机 =====================
// 按键表见 io/ui_key_router.v（R8-0a：K1~K4 消抖、单击 / 长按都在 ui_key_router 里）
wire        bc_freeze;
wire        thumb_key_right, thumb_key_left, thumb_key_confirm, thumb_key_mode;
wire        pipe_next_event, pipe_prev_event, pipe_preview_event, pipe_select_event;
wire [2:0]  pipe_select_index;
wire        pipe_auto_cfg_valid, pipe_auto_cfg_enabled, pipe_no_transition;
wire [7:0]  pipe_brightness, pipe_contrast;
wire [1:0]  pipe_sat;                // R8-2 显示页：色彩
wire [2:0]  disp_scol;               //   片内字幕颜色
wire [2:0]  pipe_pending_index;
wire        pipe_request_busy, pipe_transition_busy, auto_run;
wire [3:0]  pipe_fx_effect, pipe_fx_speed;
wire [31:0] geo_stepx, geo_startx, geo_stepy, geo_starty;
wire        geo_mirror, geo_flip;
wire        cpr_active, cpr_mode_302;
wire        cpr_beat, key_tick;      // R7c-1：节拍音 / 按键音触发（sd_card_clk 单拍）
wire [2:0]  cpr_state;
wire [15:0] cpr_timer_bcd;
wire [1:0]  ui_page;
wire        menu_visible, status_osd_en, stat_on, menu_disp;
wire        hint_show, hint_leave, txt_we;
wire [7:0]  txt_addr;
wire        layer_en, layer_sel_en;
wire [1:0]  ly_sel;
wire [3:0]  ly_show;
wire [27:0] ly_x;
wire [23:0] ly_y;
wire [15:0] ly_alpha;
wire [7:0]  ly_z, ly_motion;
wire [10:0] txt_data;
wire [7:0]  cur_index_sd;           // 当前第几张：video_clk -> sd_card_clk（状态栏）
wire [21:0] cur_wh_sd;              // R8-5c：当前图原始 {宽, 高}（sd_card_bmp 查表 -> 状态栏第四行）
wire [7:0]  menu_vol_gain;
wire [2:0]  menu_viz;
wire        music_on;
// R8-1c：电脑串口换字幕（sd_card_clk 域）
wire        sub_bm_we, sub_ovr, sub_all, sub_upd, sub_rst, sub_show;
wire [9:0]  sub_bm_addr;
wire [7:0]  sub_bm_data;
wire [2:0]  sub_pic, sub_color;
wire [1:0]  sub_speed, sub_mot;
// R9：急救语音 / 位置条 / 进度框
wire        u_loc_we, u_loc_ev;          // 串口 CMD 03 位置点阵（地址 / 数据同 sub_bm_*）
wire        loc_we;
wire [9:0]  loc_addr;
wire [7:0]  loc_data;
wire [9:0]  loc_ra;                      // 写回 SAVE.BIN 时读位置点阵（emg_overlay 的 sd_card_clk 读口）
wire [7:0]  loc_q;
wire        guide_found;
wire [31:0] guide_lba;
wire        g_own, g_play, cpr_beep;
wire [5:0]  g_seg;
wire [1:0]  cpr_part;
wire        note_show;                       // R11：急救正中黄框
wire [3:0]  cpr_led;
wire        cpr_blow;          // R12d：吹气那 1 秒（吹气音）
assign led = cpr_led;
wire        wav_sd_enable;
uart_subtitle u_uart_sub (
    .clk       (sd_card_clk),
    .rst_n     (sdcard_rst_n),
    .rx_in     (uart_rx),
    .tx_out    (uart_tx),
    .cur_pic   (cur_index_sd[2:0]),
    .bm_we     (sub_bm_we),
    .bm_addr   (sub_bm_addr),
    .bm_data   (sub_bm_data),
    .loc_we    (u_loc_we),
    .ev_loc    (u_loc_ev),
    .sub_ovr   (sub_ovr),
    .sub_all   (sub_all),
    .sub_pic   (sub_pic),
    .sub_color (sub_color),
    .sub_speed (sub_speed),
    .ev_upd    (sub_upd),
    .ev_rst    (sub_rst),
    .ev_show   (sub_show),
    .ev_mot    (sub_mot)
);
ui_key_router #(
    .CLKS_PER_MS    (100_000),
    .EXT_MS         (1),            // R12b：用顶层共用的 1ms 节拍
    .SW_ON_LEVEL    (1'b1)          // 手册：拨上 = 1。上板若发现方向反了，改成 1'b0
) u_ui_router (
    .clk                   (sd_card_clk),
    .ms_tick_in            (ms_tick_sd),
    .rst_n                 (sdcard_rst_n),
    .display_valid         (display_valid),
    .img_found_count       (img_found_count),
    .image_complete        (loader_image_complete),
    .emg_ok                (emg_ok),
    .k1_n                  (key0),
    .k2_n                  (key1),
    .k3_n                  (key3),
    .k4_n                  (key2),
    .sw1_in                (sw1),
    .sw2_in                (sw2),
    .sw3_in                (sw3),
    .sw4_in                (sw4),
    .thumb_view            (thumb_view),
    .thumb_focus           (thumb_focus),
    .pending_index         (pipe_pending_index),
    .request_busy          (pipe_request_busy),
    .transition_busy       (pipe_transition_busy),
    .auto_enabled          (auto_enabled),
    .cur_index             (cur_index_sd[2:0]),
    .cur_wh                (cur_wh_sd),
    .fault_code            (fault_code),
    .fault_arg             (fault_arg),
    .fault_tot             (fault_tot),
    .tfok_hint             (tf_recovered),
    .sub_upd               (sub_upd),
    .sub_rst               (sub_rst),
    .sub_show              (sub_show),
    .sub_mot               (sub_mot),
    .save_ld               (save_ld),
    .save_dat              (save_dat),
    .save_req              (save_req),
    .save_img              (save_img),
    .save_fail             (save_fail),
    .guide_ok              (guide_found && wav_sd_enable),
    .g_own                 (g_own),
    .g_play                (g_play),
    .g_seg                 (g_seg),
    .cpr_beep              (cpr_beep),
    .cpr_part              (cpr_part),
    .cpr_led               (cpr_led),
    .cpr_blow              (cpr_blow),
    .menu_brightness       (menu_brightness),
    .menu_contrast         (menu_contrast),
    .menu_sat              (),
    .sub_color             (disp_scol),
    .auto_int              (),
    .pipe_sat              (pipe_sat),
    .pipe_next_event       (pipe_next_event),
    .pipe_prev_event       (pipe_prev_event),
    .pipe_preview_event    (pipe_preview_event),
    .pipe_select_event     (pipe_select_event),
    .pipe_select_index     (pipe_select_index),
    .pipe_auto_cfg_valid   (pipe_auto_cfg_valid),
    .pipe_auto_cfg_enabled (pipe_auto_cfg_enabled),
    .pipe_no_transition    (pipe_no_transition),
    .emg_ovr_en            (emg_ovr_en),
    .emg_ovr_bank          (emg_ovr_bank),
    .emg_ovr_black         (emg_ovr_black),
    .pipe_fx_effect        (pipe_fx_effect),
    .pipe_fx_speed         (pipe_fx_speed),
    .geo_stepx             (geo_stepx),
    .geo_startx            (geo_startx),
    .geo_stepy             (geo_stepy),
    .geo_starty            (geo_starty),
    .geo_mirror            (geo_mirror),
    .geo_flip              (geo_flip),
    .auto_run              (auto_run),
    .pipe_brightness       (pipe_brightness),
    .pipe_contrast         (pipe_contrast),
    .thumb_key_right       (thumb_key_right),
    .thumb_key_left        (thumb_key_left),
    .thumb_key_confirm     (thumb_key_confirm),
    .thumb_key_mode        (thumb_key_mode),
    .bc_freeze             (bc_freeze),
    .cpr_active            (cpr_active),
    .cpr_state             (cpr_state),
    .cpr_mode_302          (cpr_mode_302),
    .cpr_breath            (),
    .cpr_beat              (cpr_beat),
    .key_tick              (key_tick),
    .cpr_timer_bcd         (cpr_timer_bcd),
    .cpr_aed_time_bcd      (),
    .sw1_on                (),
    .sw4_on                (music_on),
    .page                  (ui_page),
    .menu_visible          (menu_visible),
    .stat_on               (stat_on),
    .menu_disp             (menu_disp),
    .hint_show             (hint_show),
    .hint_leave            (hint_leave),
    .fault_show            (fault_show),
    .note_show             (note_show),
    .txt_we                (txt_we),
    .txt_addr              (txt_addr),
    .txt_data              (txt_data),
    .layer_en              (layer_en),
    .layer_sel_en          (layer_sel_en),
    .ly_sel                (ly_sel),
    .ly_show               (ly_show),
    .ly_x                  (ly_x),
    .ly_y                  (ly_y),
    .ly_alpha              (ly_alpha),
    .ly_z                  (ly_z),
    .ly_motion             (ly_motion),
    .vol_gain              (menu_vol_gain),
    .vw_viz                (menu_viz),
    .status_osd_en         (status_osd_en)
);

// 第11课：WAV 音频播放
wire        music_found;

// R4：故障 / 警告判定（正中故障条）
tf_fault_monitor #(.CLKS_PER_MS(100_000), .EXT_MS(1)) u_tf_fault (
    .clk           (sd_card_clk),
    .ms_tick_in    (ms_tick_sd),
    .rst_n         (sdcard_rst_n),
    .display_valid (display_valid),
    .sd_ready      (tf_sd_ready),
    .boot_done     (tf_boot_done),
    .fs_error      (fs_error),
    .found_mask    (tf_found_mask),
    .giveup_mask   (tf_giveup_mask),
    .tf_lost       (tf_lost),
    .music_found   (music_found),
    .music_on      (music_on),
    .crc_fail_cnt  (crc_fail_cnt),
    .load_idx      (loader_image_index),
    .suppress      (cpr_active),
    .code          (fault_code),
    .arg           (fault_arg),
    .tot           (fault_tot)
);
wire [31:0] music_start_lba;
wire [31:0] music_sectors;
wire         save_ld;          // R8-4a：开机读到有效 SAVE.BIN（sd_card_bmp -> ui_key_router）
wire [199:0] save_dat;
wire         save_req, save_fail;   // R8-4b：写回 SAVE.BIN（ui_key_router -> sd_card_bmp）
wire [255:0] save_img;
wire        wav_sector_req;
wire [31:0] wav_sector_lba;
wire        wav_sector_busy, wav_sector_valid, wav_sector_done;
wire [7:0]  wav_sector_byte, wav_sector_error;
wire [8:0]  wav_sector_byte_index;
wire        pix_frame_start;
wire [7:0]  fade_alpha;
wire        fade_active;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

// HDMI 1.4b 相关
wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;


//=== 第5课 2.1/2.2：复位源 + 每个时钟域一个复位同步器（异步压下、同步释放） ===
// 复位源：上电复位 + 两个 PLL 都锁定（音频 PLL 第3课已去掉）
// R7a：K1 改成轮播键，复位改为内部上电复位：配置完成后寄存器为 0，50MHz 晶振数 2^19 拍（约 10ms）后释放，之后不再复位。
//   要整板重来按 Config1（PROGRAM_B，从 Flash 重新加载）。
reg  [19:0] por_cnt = 20'd0;
always @(posedge clk)
    if (!por_cnt[19])
        por_cnt <= por_cnt + 20'd1;
wire rst_n = por_cnt[19];
wire sys_pll_lock;
wire video_pll_lock;
wire ext_rst_n = rst_n & sys_pll_lock & video_pll_lock;
wire sdcard_rst_n;     // sd_card_clk 域
wire mem_rst_n;        // ext_mem_clk 域
wire video_rst_n;      // video_clk 域

reset_sync u_sdcard_reset (
    .clk        (sd_card_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (sdcard_rst_n)
);

// R12b 资源：sd_card_clk 域共用一个 1ms 节拍（sd_card_bmp / ui_key_router / page_menu_ctrl / tf_fault_monitor 原来各数一个 17 位分频器）
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        ms_div_sd  <= 17'd0;
        ms_tick_sd <= 1'b0;
    end else begin
        ms_tick_sd <= (ms_div_sd == 17'd99_999);
        ms_div_sd  <= (ms_div_sd == 17'd99_999) ? 17'd0 : ms_div_sd + 17'd1;
    end
end

reset_sync u_mem_reset (
    .clk        (ext_mem_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (mem_rst_n)
);

reset_sync u_video_reset (
    .clk        (video_clk),
    .ext_rst_n  (ext_rst_n),
    .rst_n_sync (video_rst_n)
);

// 第5课 2.2 第三步（严谨方案）：Sdr_init_done 从 ext_mem_clk 域同步到 sd_card_clk 域
wire Sdr_init_done_sd;
sync_2ff u_sdram_init_sync (
    .clk        (sd_card_clk),
    .rst_n      (sdcard_rst_n),
    .async_in   (Sdr_init_done),
    .sync_out   (Sdr_init_done_sd)
);
//=== 修改结束 ===

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (~rst_n),       // 第5课：原来接 1'b0
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (~rst_n),       // 第5课：原来接 1'b0
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4),
    .AUTO_PLAY_MS      (3000),
    .EXT_MS            (1)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .ms_tick_in        (ms_tick_sd),
    .rst               (~sdcard_rst_n),
    .sdram_init_done   (Sdr_init_done_sd),
    .state_code        (state_code),
    .loading           (img_loading),
    .last_load_time    (last_load_time),
    .last_load_err     (last_load_err),
    .abort_code        (abort_code),
    .abort_sd_stage    (abort_sd_stage),
    .crc_err_cnt       (crc_err_cnt),
    .rd_retry_cnt      (rd_retry_cnt),
    .crc_fail_cnt      (crc_fail_cnt),
    .fs_error          (fs_error),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),
    .img_found_count   (img_found_count),
    .sd_ready          (tf_sd_ready),
    .boot_done         (tf_boot_done),
    .found_mask        (tf_found_mask),
    .giveup_mask       (tf_giveup_mask),
    .emg_ok            (emg_ok),
    .tf_lost           (tf_lost),
    .tf_recovered      (tf_recovered),

    .loader_load_start   (loader_load_start),
    .loader_image_index  (loader_image_index),
    .loader_pixel_valid  (loader_pixel_valid),
    .loader_pixel_rgb    (loader_pixel_rgb),
    .loader_pixel_ready  (loader_pixel_ready),
    .loader_top_down     (loader_top_down),
    .cur_pic             (cur_index_sd[2:0]),
    .cur_wh              (cur_wh_sd),
    .loader_frame_commit (loader_frame_commit),
    .loader_decode_error (loader_decode_error),
    .loader_load_done    (loader_load_done),
    .loader_memory_error (loader_memory_error),
    .cdc_clear           (cdc_clear),
    .cdc_idle            (cdc_idle_sd),

    .music_found           (music_found),
    .music_start_lba       (music_start_lba),
    .music_sectors         (music_sectors),
    .save_ld               (save_ld),
    .save_dat              (save_dat),
    .save_req              (save_req),
    .save_img              (save_img),
    .save_fail             (save_fail),
    .guide_found           (guide_found),
    .guide_lba             (guide_lba),
    .u_loc_we              (u_loc_we),
    .u_loc_addr            (sub_bm_addr),
    .u_loc_data            (sub_bm_data),
    .u_loc_ev              (u_loc_ev),
    .loc_we                (loc_we),
    .loc_addr              (loc_addr),
    .loc_data              (loc_data),
    .loc_ra                (loc_ra),
    .loc_q                 (loc_q),
    .wav_sd_enable         (wav_sd_enable),
    .wav_sector_req        (wav_sector_req),
    .wav_sector_lba        (wav_sector_lba),
    .wav_sector_busy       (wav_sector_busy),
    .wav_sector_valid      (wav_sector_valid),
    .wav_sector_byte       (wav_sector_byte),
    .wav_sector_byte_index (wav_sector_byte_index),
    .wav_sector_done       (wav_sector_done),
    .wav_sector_error      (wav_sector_error),

    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

// R9 资源：数码管诊断（加载耗时 / E、F 错误码 / 按住 K3 看 CRC 次数 / 急救计时）删掉，数码管全灭。
//   不上 HDMI、视频里看不到；sd_card_bmp 的诊断输出没人接，综合自动裁掉（CRC 重读、crc_fail_cnt 故障提示照旧）
assign seg_sel  = 6'b111111;
assign seg_data = 8'hff;

assign disp_img_no  = display_valid ? ({1'b0, active_index} + 4'd1) : 4'd0;
assign auto_play_on = auto_run;

// ===================== 第8课：四 bank 帧缓存（文档 5.4 修改点1~6） =====================
// 删掉官方 frame_read_write / video_timing_data / video_delay，换成：
//   写：sd_card_bmp 像素流 -> media_frame_loader（sd_card_clk，FIFO + 128 字 burst，第 n 张写 bank n）
//       -> media_sdram_write_cdc（异步 FIFO，按 128 字整块交给 ext_mem_clk）-> SDRAM 写口
//   读：media_video_pipeline = video_timing_ctrl + media_player_control + media_frame_reader + rgb_video_adapter
//       （reader 在 ext_mem_clk 发 burst 读，异步 FIFO 送到 video_clk；切图在帧消隐期提交，换 bank 不用重新加载）
// 加载和显示不重叠：四张图全部写完、CDC 排空后才打开 reader（display_valid），SDRAM 读写不会同时进行。

media_frame_loader #(
    .ADDR_WIDTH     (21),
    .IMAGE_WORDS    (FRAME_PIXELS),
    .FIFO_DEPTH     (512),
    .BURST_SIZE     (128),
    .STALL_TIMEOUT  (65535),
    .V_FLIP         (1),               // BMP 自下而上存放，写入时上下翻转（同官方 WRITE_V_FLIP=1）
    .IMAGE_WIDTH    (640),
    .IMAGE_HEIGHT   (480)
) u_loader (
    .clk                 (sd_card_clk),
    .rst_n               (sdcard_rst_n),
    .load_start          (loader_load_start),
    .image_index         (loader_image_index),
    .pixel_valid         (loader_pixel_valid),
    .pixel_rgb           (loader_pixel_rgb),
    .pixel_ready         (loader_pixel_ready),
    .top_down            (loader_top_down),
    .frame_commit        (loader_frame_commit),
    .decode_error        (loader_decode_error),
    .load_busy           (loader_load_busy),
    .load_done           (loader_load_done),
    .image_complete      (loader_image_complete),
    .memory_error        (loader_memory_error),
    .controller_init_done(Sdr_init_done_sd),
    .controller_busy     (1'b0),
    .refresh_active      (1'b0),
    .app_wr_en           (loader_app_wr_en),
    .app_wr_addr         (loader_app_wr_addr),
    .app_wr_mask         (loader_app_wr_mask),
    .app_wr_data         (loader_app_wr_data)
);

// loader 在 sd_card_clk（100MHz），SDRAM 控制器在 ext_mem_clk（125MHz）：用课程的 media_sdram_write_cdc 跨域
// （文档 5.1 注意事项）。加载失败时 sd_card_bmp 拉 cdc_clear，两侧一起复位，丢掉不完整的半个 burst。
reset_sync u_cdc_src_reset (.clk(sd_card_clk), .ext_rst_n(sdcard_rst_n & ~cdc_clear), .rst_n_sync(cdc_src_rst_n));
reset_sync u_cdc_dst_reset (.clk(ext_mem_clk), .ext_rst_n(mem_rst_n & ~cdc_clear),    .rst_n_sync(cdc_dst_rst_n));

media_sdram_write_cdc #(
    .ADDR_WIDTH      (21),
    .FIFO_ADDR_WIDTH (9),
    .BURST_SIZE      (128)
) u_sdram_write_cdc (
    .src_clk         (sd_card_clk),
    .src_rst_n       (cdc_src_rst_n),
    .src_wr_en       (loader_app_wr_en),
    .src_wr_addr     (loader_app_wr_addr),
    .src_wr_mask     (loader_app_wr_mask),
    .src_wr_data     (loader_app_wr_data),
    .src_full        (),
    .src_overflow    (cdc_overflow),
    .dst_clk         (ext_mem_clk),
    .dst_rst_n       (cdc_dst_rst_n),
    .dst_app_wr_en   (App_wr_en),
    .dst_app_wr_addr (App_wr_addr),
    .dst_app_wr_mask (App_wr_dm),
    .dst_app_wr_data (App_wr_din),
    .dst_idle        (cdc_idle_mem),
    .dst_burst_allowed (!Sdr_busy && !Sdr_init_ref_vld)
);

sync_2ff #(.RESET_VAL(1'b0)) u_cdc_idle_sync (
    .clk(sd_card_clk), .rst_n(sdcard_rst_n), .async_in(cdc_idle_mem), .sync_out(cdc_idle_sd)
);
sync_2ff #(.RESET_VAL(1'b0)) u_player_enable_sync (
    .clk(ext_mem_clk), .rst_n(mem_rst_n), .async_in(display_valid), .sync_out(player_enable_mem)
);

wire       pipe_hs, pipe_vs, pipe_de;
wire [23:0] pipe_rgb;

media_video_pipeline #(
    .IMAGE_WORDS            (FRAME_PIXELS),
    .FIFO_DEPTH             (512),
    .FIFO_MARGIN            (16),
    .H_ACT(640), .H_FP(16), .H_SYNC(96), .H_BP(48),
    .V_ACT(480), .V_FP(10), .V_SYNC(2),  .V_BP(33),
    .DEFAULT_PERIOD_CYCLES  (32'd300_000_000),     // 自动轮播 3 秒（ctrl_clk = sd_card_clk 100MHz，保持第三讲的 3 秒）
    .MIN_PERIOD_CYCLES      (32'd100_000_000),
    .MAX_PERIOD_CYCLES      (32'd3_000_000_000),
    .FADE_FRAMES            (16)                   // 第10课：16 帧（约 0.27s）转场。K2 手动：淡出到黑 -> 换图 -> 淡入；自动轮播：Wipe 揭示
) u_video_pipeline (
    .ctrl_clk            (sd_card_clk),
    .ctrl_rst_n          (sdcard_rst_n),
    .next_event          (pipe_next_event),
    .prev_event          (pipe_prev_event),
    .preview_event       (pipe_preview_event),
    .select_event        (pipe_select_event),
    .select_index        (pipe_select_index),
    .thumb_view          (thumb_view),
    .thumb_focus         (thumb_focus),
    .toggle_auto_event   (1'b0),                   // 轮播改由 SW1（auto_cfg）
    .no_transition       (pipe_no_transition),
    .emg_ovr_en          (emg_ovr_en),
    .emg_ovr_bank        (emg_ovr_bank),
    .emg_ovr_black       (emg_ovr_black),
    .fx_effect           (pipe_fx_effect),
    .fx_speed            (pipe_fx_speed),
    .geo_stepx           (geo_stepx),
    .geo_startx          (geo_startx),
    .geo_stepy           (geo_stepy),
    .geo_starty          (geo_starty),
    .geo_mirror          (geo_mirror),
    .geo_flip            (geo_flip),
    .period_cfg_valid    (1'b0),
    .period_cfg_cycles   (32'd0),
    .auto_cfg_valid      (pipe_auto_cfg_valid),
    .auto_cfg_enabled    (pipe_auto_cfg_enabled),
    .image_complete      (loader_image_complete),
    .emg_ok              (emg_ok),
    .player_enable       (player_enable_mem),

    .mem_clk             (ext_mem_clk),
    .mem_rst_n           (mem_rst_n),
    .controller_init_done(Sdr_init_done),
    .controller_busy     (Sdr_busy),
    .refresh_active      (Sdr_init_ref_vld),
    .app_rd_en           (App_rd_en),
    .app_rd_addr         (App_rd_addr),
    .sdram_rd_valid      (Sdr_rd_en),              // 文档 3.3：Sdr_rd_en 就是“读数据有效”
    .sdram_rd_data       (Sdr_rd_dout),

    .brightness          (pipe_brightness),
    .contrast            (pipe_contrast),
    .saturation          (pipe_sat),
    .status_osd_en       (status_osd_en),
    .pix_clk             (video_clk),
    .pix_rst_n           (video_rst_n),
    .video_clk           (),
    .video_hs            (pipe_hs),
    .video_vs            (pipe_vs),
    .video_de            (pipe_de),
    .video_rgb           (pipe_rgb),
    .video_x             (),                       // 不用：bridge 需要 0~799 的整行计数，下面自己数
    .active_index        (active_index),
    .pending_index       (pipe_pending_index),
    .request_busy        (pipe_request_busy),
    .transition_busy     (pipe_transition_busy),
    .auto_enabled        (auto_enabled),
    .frame_start         (pix_frame_start),
    .fade_alpha_out      (fade_alpha),
    .fade_active_out     (fade_active),
    .reader_busy         (),
    .reader_underflow    (reader_underflow),
    .video_error         (video_error)
);

assign hs        = pipe_hs;
assign vs        = pipe_vs;
assign de        = pipe_de;
assign vout_data = pipe_rgb;

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== HDMI 音视频（第3课 media_hdmi_audio_bridge） =====================
// 视频 + PCM 旋律在 bridge 里直接组成数据岛并做 TMDS 编码，输出三路 10bit 符号给 PHY，
// 不再经过官方 AXIS 转换和加密 HDMI 核。
// video_x：行内像素计数，有效区第一个像素为 0（bridge 按 800 点/行的 640x480 时序安排前导码和数据岛）
reg       de_d;
reg [9:0] hcnt;
wire      de_rise = de & ~de_d;
wire [9:0] video_x = de_rise ? 10'd0 : hcnt;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        de_d <= 1'b0;
        hcnt <= 10'd0;
    end else begin
        de_d <= de;
        if (de_rise)
            hcnt <= 10'd1;
        else if (hcnt == 10'd799)
            hcnt <= 10'd0;
        else
            hcnt <= hcnt + 10'd1;
    end
end

// ===================== 第11课：WAV 流式播放（文档 4.2） =====================
// TF 卡根目录的 MUSIC.WAV（tools/make_music_wav.py 生成：48kHz 16bit 单声道，PCM 从文件第 512 字节开始）
// 图片全部加载完以后，SD 读卡口交给 wav_stream_player；写侧 sd_card_clk，读侧 video_clk（音频链时钟）
// R1.5a：循环播放；SW4 关 = 音量斜坡降到 0 后暂停，SW4 开 = 从暂停处接着放、音量斜坡升回
// R9：急救中播放器归语音（guide_seq）：GUIDE.WAV 第 g_seg 段，起点 = guide_lba + g_seg × 1024，1024 扇区不循环；
//   平时播 MUSIC.WAV。音源切换（进 / 出急救）时 src_gap 先把播放器关 4096 拍，缓冲清空后再换
reg        src_g;
reg [12:0] src_gap;
reg [31:0] g_lba;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        src_g <= 1'b0;  src_gap <= 13'd0;
    end else if (src_g != g_own) begin
        src_g <= g_own;  src_gap <= 13'd4095;
    end else if (src_gap != 13'd0)
        src_gap <= src_gap - 13'd1;
end
always @(posedge sd_card_clk) g_lba <= {guide_lba[31:10] + {16'd0, g_seg}, guide_lba[9:0]};   // 段 × 1024 扇区：低 10 位不变
// 时序：音源选择全部寄存一拍（播放器里 32 位扇区比较 / 起点装载不再挂在选择器后面）
reg                wav_play_enable;
reg  [31:0]        wav_start_lba, wav_total_sec;
always @(posedge sd_card_clk) begin
    wav_play_enable <= wav_sd_enable && (src_gap == 13'd0) && (src_g ? (g_play && guide_found) : music_found);
    wav_start_lba   <= src_g ? g_lba : music_start_lba;
    wav_total_sec   <= src_g ? 32'd1024 : music_sectors;
end
wire signed [15:0] wav_sample;
wire               wav_sample_valid;
wire               wav_stream_active;
wire               wav_pause;

// 48kHz 采样节拍：25MHz 小数分频（与 pcm_media_tone 同样的累加器写法）
reg [24:0] wav_rate_acc;
wire       wav_sample_tick = (wav_rate_acc >= 25'd25_000_000 - 25'd48_000);
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        wav_rate_acc <= 25'd0;
    else if (wav_sample_tick)
        wav_rate_acc <= wav_rate_acc + 25'd48_000 - 25'd25_000_000;
    else
        wav_rate_acc <= wav_rate_acc + 25'd48_000;
end

wav_stream_player #(
    .ADDR_WIDTH         (12),
    .SAMPLES_PER_SECTOR (256),
    .LOOP               (1'b1)
) u_wav_stream_player (
    .wr_clk         (sd_card_clk),
    .wr_rst_n       (sdcard_rst_n),
    .play_enable    (wav_play_enable),
    .loop_en        (!src_g),
    .start_lba      (wav_start_lba),
    .total_sectors  (wav_total_sec),
    .sd_req         (wav_sector_req),
    .sd_lba         (wav_sector_lba),
    .sd_busy        (wav_sector_busy),
    .sd_valid       (wav_sector_valid),
    .sd_byte        (wav_sector_byte),
    .sd_byte_index  (wav_sector_byte_index),
    .sd_done        (wav_sector_done),
    .sd_error       (wav_sector_error),
    .rd_clk         (video_clk),
    .rd_rst_n       (video_rst_n),
    .sample_tick    (wav_sample_tick),
    .sample_out     (wav_sample),
    .sample_valid   (wav_sample_valid),
    .sample_ready   (1'b1),             // 文档：our chain 恒为 1（下游另有 FIFO）
    .pause          (wav_pause),
    .sample_counter (),
    .stream_active  (wav_stream_active),
    .stream_end     (),
    .buffer_low     ()
);

// R1：音量 / 可视化选择从 sd_card_clk 域整组快照过来；音量每个 48kHz 样点向目标走 1 级（满程约 5ms，不爆音）
wire [7:0] vol_target_v;
wire [7:0] viz_pack_v;
wire [2:0] viz_v = viz_pack_v[2:0];
error_snapshot_cdc u_vol_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n), .src_code(src_g ? 8'd255 : menu_vol_gain),   // R9：急救语音固定满音量（不受 SW4 / 菜单音量影响）
    .dst_clk(video_clk), .dst_rst_n(video_rst_n), .dst_code(vol_target_v)
);
error_snapshot_cdc u_viz_cdc (
    .src_clk(sd_card_clk), .src_rst_n(sdcard_rst_n), .src_code({3'd0, src_g, music_on, menu_viz}),
    .dst_clk(video_clk), .dst_rst_n(video_rst_n), .dst_code(viz_pack_v)
);
reg [7:0] vol_cur;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n)
        vol_cur <= 8'd0;
    else if (wav_sample_tick) begin
        if (vol_cur < vol_target_v)      vol_cur <= vol_cur + 8'd1;
        else if (vol_cur > vol_target_v) vol_cur <= vol_cur - 8'd1;
    end
end
// SW4 关：等音量斜坡降到 0 再暂停（不爆音）；SW4 开立即恢复，音量从 0 升上来
assign wav_pause = !viz_pack_v[3] && (vol_cur == 8'd0) && !viz_pack_v[4];   // R9：急救语音不受 SW4 暂停

// 音画同步：图像淡出时声音同步淡出（文档 2.4；音频链也在 video_clk 域）
wire [7:0] audio_fade_gain;
sync_fade_gain u_sync_fade_gain (
    .pix_clk     (video_clk),
    .pix_rst_n   (video_rst_n),
    .frame_start (pix_frame_start),
    .alpha_pix   (fade_alpha),
    .fade_active (fade_active),
    .aud_clk     (video_clk),
    .aud_rst_n   (video_rst_n),
    .gain_aud    (audio_fade_gain)
);

// ===================== R3：图层合成（台标 / 字幕 / 画中画 / 波形，替代原固定位置的 promax_audio_waveform）=====================
wire [13:0] font_b_addr;
wire [7:0]  font_b_q;
reg  [1:0]  thumb_s;                 // 缩略图模式同步到 video_clk（画中画抽样时避开）
always @(posedge video_clk or negedge video_rst_n)
    if (!video_rst_n) thumb_s <= 2'b00; else thumb_s <= {thumb_s[0], thumb_view};
wire [23:0] wave_rgb;
layer_compositor u_layers (
    .clk           (video_clk),
    .rst_n         (video_rst_n),
    .vsync         (vs),
    .de            (de),
    .pixel_x       (video_x),
    .rgb_in        (vout_data),
    .rgb_out       (wave_rgb),
    .enable_async  (layer_en),
    .sel_en_async  (layer_sel_en),
    .sel_async     (ly_sel),
    .show_async    (ly_show),
    .x_async       (ly_x),
    .y_async       (ly_y),
    .alpha_async   (ly_alpha),
    .z_async       (ly_z),
    .motion_async  (ly_motion),
    .wave_en       (wav_stream_active && viz_v != 3'd0),
    .viz           (viz_v),                                   // R6：波形 / 示波器 / 音量表    // VIEW 页 可视化=关 也关掉波形层
    .pcm_valid     (wav_sample_valid),
    .pcm           (wav_sample),
    .cap_en        (!fade_active && !thumb_s[1]),
    .img_idx       (active_index),
    .wclk          (sd_card_clk),
    .we            (txt_we),
    .waddr         (txt_addr),
    .wdata         (txt_data),
    .bm_we         (sub_bm_we),
    .bm_addr       (sub_bm_addr),
    .bm_data       (sub_bm_data),
    .sub_ovr_async (sub_ovr),
    .sub_all_async (sub_all),
    .sub_pic_async (sub_pic),
    .sub_color_async (sub_color),
    .sub_speed_async (sub_speed),
    .sub_col_async (disp_scol),
    .fb_addr       (font_b_addr),
    .fb_q          (font_b_q)
);

// ===================== R1.5b：中文状态栏 / 设置菜单 / 提示条（最上层）=====================
error_snapshot_cdc u_idx_cdc (
    .src_clk(video_clk), .src_rst_n(video_rst_n), .src_code({5'd0, active_index}),
    .dst_clk(sd_card_clk), .dst_rst_n(sdcard_rst_n), .dst_code(cur_index_sd)
);
// R9：急救叠加层（进度框 / 位置条 / 民法典角标，跟节拍脉动）
reg beat_tg;
always @(posedge sd_card_clk or negedge sdcard_rst_n)
    if (!sdcard_rst_n) beat_tg <= 1'b0;
    else if (cpr_beat) beat_tg <= ~beat_tg;
wire [23:0] emg_rgb;
emg_overlay u_emg (
    .clk        (video_clk),
    .rst_n      (video_rst_n),
    .vsync      (vs),
    .de         (de),
    .pixel_x    (video_x),
    .rgb_in     (wave_rgb),
    .rgb_out    (emg_rgb),
    .en_async   (cpr_active),
    .part_async (cpr_part),
    .beat_tog   (beat_tg),
    .wclk       (sd_card_clk),
    .loc_we     (loc_we),
    .loc_addr   (loc_addr),
    .loc_data   (loc_data),
    .loc_ra     (loc_ra),
    .loc_q      (loc_q)
);
wire [23:0] menu_rgb;
cn_text_overlay u_cn_osd (
    .clk              (video_clk),
    .rst_n            (video_rst_n),
    .vsync            (vs),
    .de               (de),
    .rgb_in           (emg_rgb),
    .pixel_x          (video_x),
    .wclk             (sd_card_clk),
    .we               (txt_we),
    .waddr            (txt_addr),
    .wdata            (txt_data),
    .menu_vis_async   (menu_visible),
    .hint_show_async  (hint_show),
    .hint_leave_async (hint_leave),
    .fault_show_async (fault_show),
    .cpr_async        (cpr_active),
    .note_show_async  (note_show),
    .stat_on_async    (stat_on),
    .menu_disp_async  (menu_disp),
    .fb_addr          (font_b_addr),
    .fb_q             (font_b_q),
    .rgb_out          (menu_rgb)
);

media_hdmi_audio_bridge u_media_hdmi_audio_bridge (
    .pixel_clk          (video_clk),
    .pixel_rst_n        (video_rst_n),
    .video_hsync        (hs),
    .video_vsync        (vs),
    .video_de           (de),
    .video_x            (video_x),
    .video_rgb          (menu_rgb),
    .media_id           (active_index[1:0]),   // 端口内部已不用（R8-0a 起没有琶音）
    .volume             (vol_cur),             // R1：VIEW 页 VOLUME，带斜坡
    .wav_valid          (wav_sample_valid),
    .wav_sample         (wav_sample),
    .wav_active         (wav_stream_active),
    .fade_gain          (audio_fade_gain),
    .cue_src_clk        (sd_card_clk),
    .cue_src_rst_n      (sdcard_rst_n),
    .beat_pulse         (cpr_beep),           // R9：有语音数数的那一拍不响
    .key_pulse          (key_tick),
    .blow_level         (cpr_blow),           // R12d：吹气那 1 秒「嘀——」（R12a 接 cpr_led[0]，按压每拍也响）
    .sample_tick        (wav_sample_tick),
    .channel0_symbol    (tmds_ch0_data),
    .channel1_symbol    (tmds_ch1_data),
    .channel2_symbol    (tmds_ch2_data),
    .sequence_error     (),
    .tone_overflow      (),
    .pcm_contract_error (),
    .blip_active        (),
    .pcm_tap_valid      (),
    .pcm_tap_left       ()
);

assign tmds_clk_data = 10'b1111100000;

// 不再读 EDID：DDC 保持空闲
assign HDMI_DDC_SCL = 1'b1;
assign HDMI_DDC_SDA = 1'bz;

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
