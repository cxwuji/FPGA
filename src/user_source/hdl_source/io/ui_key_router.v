`timescale 1ns/1ps

// 按键 / 拨码路由（sd_card_clk 域）。顶层与 sim/tb_fourbank.v 共用，保证仿真测的就是板上的连法。
//
// 交互规范 v2（doc/交互与显示规范_v2.md，R1.5a）：
//   SW1 开 = 设置模式：SW3 SW2 选页 00 PLAY / 01 TRANS / 10 LAYER / 11 VIEW；SW1 关 = 播放模式，一律按 00 页，
//     此时拨 SW2/SW3 到非 00 只弹提示「请先打开 SW1 进入设置」。SW4 = 背景音乐开 / 关（关 = 音量斜坡到 0 后暂停）。
//   page 01~11 由 page_menu_ctrl 处理：K2 单击 / 长按 = 下一项 / 上一项，K3 = 加 / 执行，K4 = 减，按住 0.5 秒后连续。
//   切到非 00 页时自动退出缩略图。左上角中文状态栏常驻（R1.5b，cn_text_overlay；旧的 ASCII 状态 OSD 关掉）。
//
// 播放页    | 全屏                       | 缩略图
//   K2 单击  | 下一张                     | 焦点右移
//   K2 长按  | 上一张                     | 焦点左移
//   K3 单击  | 亮度 255/192/128/64        | —
//   K3 长按  | 对比度（满 1 秒即生效）；按住显示诊断页 | —
//   K4 单击  | 自动轮播 开 / 关（多于 1 张才真正轮播） | 确认，全屏显示焦点图
//
// R2：自动轮播计时从 media_player_control 移到这里（每 AUTO_MS 发一次"下一张"，转场进行中暂停），
//   这样轮播也走转场引擎的"消失 -> 出现"。每次切图（K2 / 轮播 / 预览）按转场页设置选效果：
//   固定 = 效果项；随机 = 0~12 伪随机；轮换 = 0~12 依次；演示开 = 强制轮换 + 自动切图 + 提示条显示效果名。
// R6 一键演示（转场页"演示"= 开）：每 2 次自动切图换一个节目，8 个节目循环，提示条显示「演示 n/8 节目名」：
//   1 转场特效  2 台标弹跳  3 字幕滚动  4 画中画  5 推拉摇移  6 镜像翻转  7 音量表（R8-2：原来是示波器）  8 频谱（R8-3）
//   节目只是临时叠加在用户设置上（关掉演示即恢复），不改菜单里的值。（R10 资源：一键演示整个删掉）
//   K4 长按  | 进入缩略图                 | 返回全屏
//
// R7a 急救（cpr_flow_ctrl）：K1 单击 = 自动轮播 开 / 关（K1 不再是复位，顶层改内部上电复位）；
//   播放页全屏 K4 单击 = 进入急救（原来的"K4 单击 = 轮播"移到 K1）。
//   急救中：K2 单击 单纯按压 / 30:2，K3 单击 下一步，K4 长按 2 秒 = 交接页；交接页 K4 长按 2 秒 = 回待机。K1 无效。
// 急救中：菜单隐藏，按键交给急救流程；亮度 / 对比度强制 255 / 128，K3 菜单冻结；所有切换硬切；轮播强制关。
// R8-2：播放模式只在 SW1 拨下时（原来 SW1 开、页 00 也算播放页）：K3 单击 = 字幕开 / 关（原来亮度 / 对比度）。
//   SW1 开、页 00 = 显示页（不是菜单，按一下改一档）：K1 亮度 / K2 对比度 / K3 色彩（标准 -> 鲜艳 -> 黑白 -> 淡）/
//   K4 单击 字幕颜色（8 色）、K4 长按 轮播间隔（3 / 5 / 8 / 10 / 15 秒）。设置模式里不能换图、不能进急救（没出图时 K4 照样能进）。
//   转场页 K1 = 预览（菜单里的「预览」项删掉）；其他设置页 K1 仍是自动轮播开 / 关。演示节目 7 示波器 -> 音量表（示波器删掉）。
// R7b-1 / R7b-2 急救覆盖（R8-1a：整个急救流程都读 bank5 = PIC6，缺失黑底），交接页亮度压到 1/4；
//   播放器的当前图不动，退出急救撤掉覆盖 = 回到被打断的那张图。
// R7b-2 新流程（cpr_flow_ctrl）：① K4 长按 2 秒 = 误触取消；② ③ K4 长按 2 秒 = 交接；K2 单击（② ③）单纯按压 / 30:2。
//   没插卡 / 图还没加载完也能急救：K4 单击（没出图时任何页）、K2、K3、K4 长按都不再依赖 display_valid。
// R8-2b：播放模式 K3 长按（满 1 秒）= 状态栏开 / 关（上电字幕、状态栏都关）；轮播间隔 6 档 1 / 3 / 5 / 8 / 10 / 15 秒（默认 3 秒）；
//   转场页 K1 预览改走 pipe_preview_event：转场引擎让当前图按效果消失再出现，不换图。
// R9 三部分急救（cpr_flow_ctrl / guide_seq，doc/R9_急救改版方案.md）：急救中 K1 单击 = 重播本部分、K1 长按 1 秒 = 语音静音 / 恢复；
//   K2 单击 = 30:2 / 单纯按压；K3 单击 = ① -> ②、② ⇄ ③；K4 长按 2 秒 = ① 取消 / ② ③ 交接 / 交接页回广告。
// R10（doc/R10_方案.md）：LED 节拍灯 cpr_led：② 每拍 4 个全亮 100 ms，其他全灭。
// R11（doc/R11_方案.md）：7A 实测按压频率删掉（K2 单击仍是 30:2 ⇄ 单纯按压）；人工呼吸只在两口吹气的那两秒（br_sec 5 / 7）亮灯。
// R12d：吹气音单独用 cpr_blow（只在那两秒为高）；R12a 直接接 cpr_led[0]，按压时每拍亮灯也会响一声。
//   播放模式 K1 改松开时判断：单击 = 自动轮播 开 / 关，按满 1 秒 = 频谱 开 / 关（viz_tog）；
//   显示页 K1：3 秒内松开 = 亮度 +1 档，按满 3 秒 = 恢复默认（去掉 R10 的 1~3 秒频谱档）。
//   轮播 5 -> 4 张（PIC1~4，bank0~3），缩略图 2x2（PIC6 不进缩略图），缩略图确认只认 0~3。
module ui_key_router #(
    parameter integer CLKS_PER_MS    = 100_000,
    parameter integer EXT_MS         = 0,          // R12b：1 = 用 ms_tick_in（顶层共用的 1ms 节拍），菜单也跟着用
    parameter         SW_ON_LEVEL    = 1'b1,
    parameter integer CPR_HOLD_MS    = 2000,
    parameter integer AUTO_MS        = 3000,
    parameter integer IMG_W          = 640,
    parameter integer IMG_H          = 480
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        ms_tick_in,         // R12b：EXT_MS = 1 时用
    input  wire        display_valid,
    input  wire [2:0]  img_found_count,
    input  wire [4:0]  image_complete,     // R8-1a：bank0~4（轮播图）
    input  wire        emg_ok,             // R8-1a：PIC6 已加载进 bank5（sd_card_bmp）
    // 原始按键电平（R8-0a：K1~K4 只在本模块消抖一次；单击 / 长按 1 秒 / 长按 2 秒、菜单 K3 / K4 连续都由消抖后的电平产生，
    //   原来 sd_card_bmp（K2 / K4）、bc_menu_controller（K3）、key_repeat（K3 / K4）各自再消抖一次）
    input  wire        k1_n,
    input  wire        k2_n,               // R7b-2：急救 K2（单纯按压 / 30:2）本模块自己消抖，没出图也能用
    input  wire        k3_n,
    input  wire        k4_n,
    // 拨码（原始电平）
    input  wire        sw1_in,
    input  wire        sw2_in,
    input  wire        sw3_in,
    input  wire        sw4_in,
    // 缩略图控制器 / 播放控制器状态
    input  wire        thumb_view,
    input  wire [2:0]  thumb_focus,
    input  wire [2:0]  pending_index,
    input  wire        request_busy,
    input  wire        transition_busy,
    input  wire        auto_enabled,
    input  wire [2:0]  cur_index,          // 当前显示第几张（已同步到本时钟域，状态栏用）
    input  wire [21:0] cur_wh,             // R8-5c：当前图原始 {宽, 高}（状态栏第四行）
    input  wire [3:0]  fault_code,         // R4：tf_fault_monitor
    input  wire [2:0]  fault_arg,
    input  wire [2:0]  fault_tot,          // R12：开机读图提示总张数
    input  wire        tfok_hint,
    input  wire        sub_upd,            // R8-1c 串口字幕事件（uart_subtitle），直接转给 page_menu_ctrl
    input  wire        sub_rst,
    input  wire        sub_show,
    input  wire [1:0]  sub_mot,
    input  wire        save_ld,            // R8-4a：单拍，开机读到有效 SAVE.BIN（sd_card_bmp，加载图片前）
    input  wire [199:0] save_dat,          //   存档前 25 字节（字节 n = [8n+7:8n]，格式见 doc/R8-4_方案.md）
    output reg         save_req,           // R8-4b：单拍，请 sd_card_bmp 把 save_img 写回 SAVE.BIN
    output wire [255:0] save_img,          //   存档前 32 字节（含校验，字节 n = [8n+7:8n]），其余 480 字节写 0
    input  wire        save_fail,          //   单拍：写卡失败（sd_card_bmp）
    input  wire        guide_ok,           // R9：有 GUIDE.WAV 且 SD 口已交给播放器（guide_seq）
    output wire        g_own,              // R9：急救中播放器归语音
    output wire        g_play,
    output wire [5:0]  g_seg,
    output wire        cpr_beep,           // R9：节拍音（这一拍没有语音数数时才响）
    output wire [1:0]  cpr_part,           // R9：进度框 0 无 / 1~3 第几部分（交接页 0）
    output reg  [3:0]  cpr_led,            // R10：板上 4 个 LED 节拍灯（高电平亮）
    output reg         cpr_blow,           // R12d：人工呼吸吹气那 1 秒（br_sec 5 / 7）= 吹气音 blow_level
    output reg  [7:0]  menu_brightness,    // R8-0a：亮度 / 对比度档位从 bc_menu_controller 挪到本模块
    output reg  [7:0]  menu_contrast,
    output reg  [1:0]  menu_sat,           // R8-2 显示页：色彩 0 黑白 1 淡 2 标准 3 鲜艳
    output reg  [2:0]  sub_color,          //   片内字幕颜色（layer_compositor）
    output reg  [2:0]  auto_int,           //   轮播间隔 0~5 = 1 / 3 / 5 / 8 / 10 / 15 秒（R8-2b 加 1 秒）
    output wire [1:0]  pipe_sat,           //   给 media_video_pipeline（急救中强制标准）
    // 给 media_video_pipeline
    output wire        pipe_next_event,
    output wire        pipe_prev_event,
    output wire        pipe_preview_event,  // R8-2b 转场页 K1：同一张图按效果消失再出现
    output wire        pipe_select_event,
    output wire [2:0]  pipe_select_index,
    output wire        pipe_auto_cfg_valid,
    output wire        pipe_auto_cfg_enabled,
    output wire        pipe_no_transition,
    output reg         emg_ovr_en,         // R7b-1 急救覆盖（给 media_video_pipeline，寄存输出）
    output reg  [2:0]  emg_ovr_bank,
    output reg         emg_ovr_black,
    output wire [3:0]  pipe_fx_effect,
    output wire [3:0]  pipe_fx_speed,
    output wire [31:0] geo_stepx,          // R5 画面变换（geom_param）
    output wire [31:0] geo_startx,
    output wire [31:0] geo_stepy,
    output wire [31:0] geo_starty,
    output wire        geo_mirror,
    output wire        geo_flip,
    output wire        auto_run,           // 自动轮播实际在跑（状态栏 / 数码管）
    output wire [7:0]  pipe_brightness,
    output wire [7:0]  pipe_contrast,
    // 给 thumbnail_controller
    output wire        thumb_key_right,
    output wire        thumb_key_left,
    output wire        thumb_key_confirm,
    output wire        thumb_key_mode,
    output wire        bc_freeze,          // 1 = 不在显示页（R8-2 起亮度 / 对比度只在显示页调）
    // CPR 状态（数码管 / OSD / 后续 LED、节拍音用）
    output wire        cpr_active,
    output wire [2:0]  cpr_state,
    output wire        cpr_mode_302,
    output wire        cpr_breath,
    output wire        cpr_beat,
    output reg         key_tick,           // R7c-1：单拍，按键音（任意键按下沿 + 长按真正生效的那一刻）
    output wire [15:0] cpr_timer_bcd,
    output wire [15:0] cpr_aed_time_bcd,
    output wire        sw1_on,
    output wire        sw4_on,
    // R1 功能页 + 菜单
    output wire [1:0]  page,
    output wire        menu_visible,
    output wire        stat_on,            // R8-2b 状态栏开 / 关（cn_text_overlay）
    output wire        menu_disp,          // R8-2b 菜单框是显示页（两行白色）
    output wire        hint_show,
    output wire        hint_leave,
    output wire        fault_show,
    output wire        note_show,          // R11：急救正中黄框（准备好后按K3 / 到了两分钟）
    output wire        txt_we,
    output wire [7:0]  txt_addr,
    output wire [10:0] txt_data,
    // R3 图层（给 layer_compositor）
    output wire        layer_en,           // 显示打开且不在急救中
    output wire        layer_sel_en,       // 图层页菜单打开：画选中框
    output wire [1:0]  ly_sel,
    output wire [3:0]  ly_show,
    output wire [27:0] ly_x,
    output wire [23:0] ly_y,
    output wire [15:0] ly_alpha,
    output wire [7:0]  ly_z,
    output wire [7:0]  ly_motion,
    output wire [7:0]  vol_gain,
    output wire [2:0]  vw_viz,
    output wire        status_osd_en
);
    // R7b-2 时序：本模块（含菜单 / 画面变换 / 急救流程）用自己的复位同步器，
    // 不再挂在 sd_card_clk 全局复位上（全局复位扇出约 2000，recovery 检查 -0.4~-4.8ns）
    wire rst_n_l, rst_n_m;
    reset_sync u_local_reset (.clk(clk), .ext_rst_n(rst_n), .rst_n_sync(rst_n_l));
    reset_sync u_menu_reset  (.clk(clk), .ext_rst_n(rst_n), .rst_n_sync(rst_n_m));   // R7c-1：菜单单独一个（扇出 700 时 recovery -1.7ns）
    wire sw2_on, sw3_on;
    wire setup_on = sw1_on;
    // R8-5a 资源：拨码 / 按键消抖和长按计时共用一个 1ms 节拍（原来 12 个 24~28 位时钟计数器，约 500 LUT）；
    //   R12b 资源：EXT_MS = 1 时用顶层共用的 1ms 节拍 ms_tick_in（本地再寄存一拍，跨模块长线留一整拍），不再自己分频
    reg [16:0] ms_div;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            ms_div <= 17'd0;  ms_tick <= 1'b0;
        end else if (EXT_MS) begin
            ms_tick <= ms_tick_in;
        end else begin
            ms_tick <= (ms_div == CLKS_PER_MS - 1);
            ms_div  <= (ms_div == CLKS_PER_MS - 1) ? 17'd0 : ms_div + 17'd1;
        end
    end
    switch_debounce #(.DEBOUNCE_MS(20), .ON_LEVEL(SW_ON_LEVEL)) u_sw1 (
        .clk(clk), .rst_n(rst_n_l), .tick(ms_tick), .sw_in(sw1_in), .on(sw1_on)
    );
    switch_debounce #(.DEBOUNCE_MS(20), .ON_LEVEL(SW_ON_LEVEL)) u_sw2 (
        .clk(clk), .rst_n(rst_n_l), .tick(ms_tick), .sw_in(sw2_in), .on(sw2_on)
    );
    switch_debounce #(.DEBOUNCE_MS(20), .ON_LEVEL(SW_ON_LEVEL)) u_sw3 (
        .clk(clk), .rst_n(rst_n_l), .tick(ms_tick), .sw_in(sw3_in), .on(sw3_on)
    );
    switch_debounce #(.DEBOUNCE_MS(20), .ON_LEVEL(SW_ON_LEVEL)) u_sw4 (
        .clk(clk), .rst_n(rst_n_l), .tick(ms_tick), .sw_in(sw4_in), .on(sw4_on)
    );
    // 页号（SW1 关时一律 00）寄存两份：page_r 给内部路由（断开"拨码消抖 -> 按键路由 -> 播放控制"这条长组合路径），
    // page_x 单独给顶层数码管诊断页（50MHz 域采样；分开后工具为跨域 hold 插的延迟不会落在内部路径上）
    reg [1:0] page_r, raw_page;
    reg [1:0] page_x;  /* fehdl keep="true" */   // R7c-1：防止综合把它和 page_r 合并（合并后跨域 hold -1ns）
    reg       p0, pl, pt;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            page_r <= 2'd0;  page_x <= 2'd0;  raw_page <= 2'd0;  p0 <= 1'b1;  pl <= 1'b1;  pt <= 1'b0;
        end else begin
            raw_page <= {sw3_on, sw2_on};
            page_r   <= setup_on ? {sw3_on, sw2_on} : 2'd0;
            page_x   <= setup_on ? {sw3_on, sw2_on} : 2'd0;
            p0       <= !setup_on || ({sw3_on, sw2_on} == 2'd0);
            pl       <= !setup_on;                                   // R8-2：播放模式
            pt       <= setup_on && ({sw3_on, sw2_on} == 2'd1);      // 转场页（K1 = 预览）
        end
    end
    assign page = page_x;

    // 按键：每个键消抖一次（20ms），再分单击（松开时判定）/ 长按 1 秒；K4 另有长按 2 秒（急救结束 / 交接页清除）
    wire k1_level, k1_press, k2_level, k2_press_any, k3_level, k3_press, k4_level, k4_press;
    wire k2_click_w, k2_hold_w, k3_click, k3_hold, k4_click_w, k4_hold_w, k4_hold2_w, k4_click_nd;
    wire k1_click_e, k1_hold_e;           // R9：急救中 K1 单击（松开时）/ 长按 1 秒，不门控 display_valid
    key_press_debounce #(.DEBOUNCE_MS(20)) u_k1_deb (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .button_in(k1_n), .press_pulse(k1_press), .button_level(k1_level)
    );
    key_press_debounce #(.DEBOUNCE_MS(20)) u_k2_deb (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .button_in(k2_n), .press_pulse(k2_press_any), .button_level(k2_level)
    );
    key_press_debounce #(.DEBOUNCE_MS(20)) u_k3_deb (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .button_in(k3_n), .press_pulse(k3_press), .button_level(k3_level)
    );
    key_press_debounce #(.DEBOUNCE_MS(20)) u_k4_deb (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .button_in(k4_n), .press_pulse(k4_press), .button_level(k4_level)
    );
    key_click_hold #(.HOLD_MS(1000)) u_k1_hold (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .level_n(k1_level), .click_pulse(k1_click_e), .hold_pulse(k1_hold_e)
    );
    key_click_hold #(.HOLD_MS(1000)) u_k2_hold (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .level_n(k2_level), .click_pulse(k2_click_w), .hold_pulse(k2_hold_w)
    );
    key_click_hold #(.HOLD_MS(1000)) u_k3_hold (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .level_n(k3_level), .click_pulse(k3_click), .hold_pulse(k3_hold)
    );
    key_click_hold #(.HOLD_MS(1000)) u_k4_hold (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .level_n(k4_level), .click_pulse(k4_click_w), .hold_pulse(k4_hold_w)
    );
    key_click_hold #(.HOLD_MS(CPR_HOLD_MS)) u_k4_hold2 (
        .clk(clk), .rst(~rst_n_l), .tick(ms_tick), .level_n(k4_level), .click_pulse(k4_click_nd), .hold_pulse(k4_hold2_w)
    );
    // K2 / K4 的 1 秒单击 / 长按：显示打开后才有效（原来 sd_card_bmp 里就是这样门控的）；K3 不门控（急救下一步）
    wire k2_click = k2_click_w & display_valid;
    wire k2_hold  = k2_hold_w  & display_valid;
    wire k4_click = k4_click_w & display_valid;
    wire k4_hold  = k4_hold_w  & display_valid;
    wire k1_click = k1_press & display_valid;
    wire k4_hold2 = k4_hold2_w;                  // R7b-2：没出图也能结束 / 取消急救

    wire [2:0]  st;
    wire [4:0]  cpr_cyc;
    wire [15:0] cpr_comp_bcd;
    wire        cpr_aed_seen;
    wire [3:0]  cpr_brs;
    wire        cpr_brev, cpr_swap, cpr_stev, cpr_intro, cpr_full;
    wire [6:0]  cpr_ssec;
    wire [7:0]  cpr_grp;
    wire        g_muted;
    assign cpr_state = st;
    wire   cpr_start;
    wire   k1_rep  = cpr_active & k1_click_e;
    wire   k1_mute = cpr_active & k1_hold_e;

    cpr_flow_ctrl u_cpr (
        .clk(clk), .rst_n(rst_n_l), .ms_tick(ms_tick), .start_event(cpr_start),
        .step_event(k3_click), .mode_event(k2_press_any), .end_event(k4_hold2), .replay_event(k1_rep),
        .cpr_active(cpr_active), .state(st), .mode_302(cpr_mode_302),
        .breath(cpr_breath), .br_sec(cpr_brs), .br_ev(cpr_brev), .swap(cpr_swap),
        .cyc(cpr_cyc), .grp_bcd(cpr_grp), .beat(cpr_beat), .comp_bcd(cpr_comp_bcd),
        .timer_bcd(cpr_timer_bcd), .aed_time_bcd(cpr_aed_time_bcd), .aed_seen(cpr_aed_seen),
        .step_sec(cpr_ssec), .step_ev(cpr_stev), .intro(cpr_intro), .intro_full(cpr_full)
    );
    guide_seq u_guide (
        .clk(clk), .rst_n(rst_n_l), .guide_ok(guide_ok), .mute_event(k1_mute),
        .st(st), .step_sec(cpr_ssec), .step_ev(cpr_stev), .br_sec(cpr_brs), .br_ev(cpr_brev),
        .intro(cpr_intro), .intro_full(cpr_full), .breath(cpr_breath), .beat(cpr_beat), .cyc(cpr_cyc),
        .g_own(g_own), .g_play(g_play), .g_seg(g_seg), .muted(g_muted), .beep(cpr_beep)
    );
    reg [1:0] part_r;
    always @(posedge clk or negedge rst_n_l)
        if (!rst_n_l) part_r <= 2'd0;
        else          part_r <= (st == 3'd1 || st == 3'd2 || st == 3'd3) ? st[1:0] : 2'd0;
    assign cpr_part = part_r;
    // R10 LED 节拍灯：每拍亮 100 ms（和语音报数 / 角标脉动同一个 beat）；R11 人工呼吸只在吹气那两秒（br_sec 5 / 7）亮
    reg  [6:0] led_ms;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            led_ms <= 7'd0;  cpr_led <= 4'd0;  cpr_blow <= 1'b0;
        end else begin
            if (cpr_beat)
                led_ms <= 7'd100;
            else if (ms_tick && led_ms != 7'd0)
                led_ms <= led_ms - 7'd1;
            cpr_led <= {4{(st == 3'd2) && (cpr_breath ? (cpr_brs == 4'd5 || cpr_brs == 4'd7) : (led_ms != 7'd0))}};
            cpr_blow <= (st == 3'd2) && cpr_breath && (cpr_brs == 4'd5 || cpr_brs == 4'd7);
        end
    end

    wire standby = !cpr_active;
    wire play = standby & pl;            // 播放模式（SW1 拨下）
    wire disp = standby & p0 & ~pl;      // R8-2 显示页（SW1 开、页 00）

    // 全屏：K2 / 自动轮播 / 转场预览
    wire   k2_next  = play & ~thumb_view & k2_click;
    wire   k2_prev  = play & ~thumb_view & k2_hold;
    wire   auto_tick;
    wire   fx_preview_w;
    wire   preview  = (fx_preview_w | (k1_click & pt)) & standby & ~thumb_view;   // R8-2：转场页 K1
    assign pipe_next_event = k2_next | auto_tick;
    assign pipe_prev_event = k2_prev;
    assign pipe_preview_event = preview;
    // 缩略图（进入急救或切到非 00 页时若在缩略图，每拍都给 key_mode，view_mode 翻一次后 thumb_view=0 即停止）
    assign thumb_key_right   = play & thumb_view & k2_click;
    assign thumb_key_left    = play & thumb_view & k2_hold;
    assign thumb_key_confirm = play & thumb_view & k4_click;
    assign thumb_key_mode    = (play & k4_hold) | (~play & thumb_view);
    wire   thumb_select      = thumb_key_confirm & (thumb_focus <= 3'd3) & image_complete[thumb_focus];   // R11：轮播 4 张
    // 出图后：播放页全屏 K4 单击；没出图（没卡 / 正在加载）：K4 单击（本模块的 2 秒长按检测给出的短按）
    assign cpr_start         = display_valid ? (play & ~thumb_view & k4_click) : (standby & k4_click_nd);
    // 播放模式（R11）：K1 松开时没满 1 秒 = 轮播开关，满 1 秒 = 频谱开关；图层 / 画面页 K1 按下 = 轮播开关；显示页 K1 = 亮度，转场页 K1 = 预览
    wire   auto_toggle       = standby & ((pl & k1_click_e & display_valid) | (k1_click & ~pl & ~p0 & ~pt));
    wire   sub_tog           = play & k3_click;                                       // R8-2 播放模式 K3：字幕开 / 关
    wire   stat_tog          = play & k3_hold;                                        // R8-2b 播放模式 K3 长按：状态栏开 / 关

    // R8-4a：存档里的当前图，显示打开那一刻硬切过去（和缩略图确认同一条路，不走转场；没加载成功的 bank 播放控制会忽略）
    reg       dv_q, boot_sel, sv_pend;
    reg [2:0] sv_idx;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            dv_q <= 1'b0;  boot_sel <= 1'b0;  sv_pend <= 1'b0;  sv_idx <= 3'd0;
        end else begin
            dv_q     <= display_valid;
            boot_sel <= 1'b0;
            if (save_ld) begin
                sv_pend <= 1'b1;
                sv_idx  <= save_dat[122:120];
            end else if (sv_pend && display_valid && !dv_q) begin
                sv_pend  <= 1'b0;
                boot_sel <= 1'b1;
            end
        end
    end
    assign pipe_select_event = thumb_select | boot_sel;
    assign pipe_select_index = boot_sel ? sv_idx : thumb_focus;

    // 自动轮播：K1 单击开 / 关（任何页，急救中无效；急救中强制关，结束后恢复）；转场演示开时也自动切图。
    // media_player_control 自己的轮播一直关着（万一开着就关掉）
    reg auto_on;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l)           auto_on <= 1'b0;
        else if (save_ld)       auto_on <= save_dat[82];
        else if (fac_now)       auto_on <= 1'b0;
        else if (auto_toggle) auto_on <= ~auto_on;
    end
    assign auto_run = auto_on & standby & display_valid & (img_found_count > 3'd1);
    assign pipe_auto_cfg_valid   = display_valid && auto_enabled;
    assign pipe_auto_cfg_enabled = 1'b0;
    // R8-2 轮播间隔（显示页 K4 长按）：0 = AUTO_MS / 3（1 秒，R8-2b），1 = AUTO_MS（默认 3 秒），之后 5 / 8 / 10 / 15 秒；比较值先寄存
    // R8-5b 资源：计时改数 1ms 节拍（原来 32 位时钟计数器 + 32 位比较）
    reg [13:0] auto_lim;
    always @(posedge clk)
        case (auto_int)
            3'd0:    auto_lim <= AUTO_MS / 3 - 1;
            3'd1:    auto_lim <= AUTO_MS - 1;
            3'd2:    auto_lim <= 14'd4999;
            3'd3:    auto_lim <= 14'd7999;
            3'd4:    auto_lim <= 14'd9999;
            default: auto_lim <= 14'd14999;
        endcase
    reg [13:0] auto_cnt;
    reg        auto_tick_r;
    reg        auto_go;                    // R8-2b 时序：急救状态 -> auto_run -> 计数器使能先寄存一拍（-0.11ns）
    always @(posedge clk) auto_go <= auto_run & ~thumb_view;
    assign auto_tick = auto_tick_r;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            auto_cnt <= 14'd0;  auto_tick_r <= 1'b0;
        end else begin
            auto_tick_r <= 1'b0;
            if (!auto_go)
                auto_cnt <= 14'd0;
            else if (transition_busy || request_busy || auto_tick_r)
                ;                                           // 转场 / 换图进行中：计时暂停
            else if (auto_cnt >= auto_lim) begin
                auto_cnt <= 14'd0;  auto_tick_r <= 1'b1;
            end else if (ms_tick)
                auto_cnt <= auto_cnt + 14'd1;
        end
    end

    // 转场效果选择：每次发出切图请求那一拍定下来（转场引擎随请求锁存）
    wire [3:0] fx_effect_w, fx_speed_w;
    wire [1:0] fx_mode_w;
    reg  [7:0] lfsr;
    reg  [3:0] cyc;
    wire [3:0] rnd13 = (lfsr[3:0] == 4'd13) ? 4'd14 : lfsr[3:0];   // R12c：随机 / 轮换都不用 13 硬切，加上 14 / 15 推移
    wire       cycle_mode = (fx_mode_w == 2'd2);
    assign pipe_fx_effect = cycle_mode ? cyc : (fx_mode_w == 2'd1) ? rnd13 : fx_effect_w;
    assign pipe_fx_speed  = fx_speed_w;
    wire   any_req = pipe_next_event | pipe_prev_event | pipe_preview_event;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            lfsr <= 8'h5a;  cyc <= 4'd0;
        end else begin
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            if (any_req && !transition_busy && cycle_mode)
                cyc <= (cyc == 4'd12) ? 4'd14 : cyc + 4'd1;          // 0 ~ 12、14、15 循环
        end
    end
    // R10 资源：一键演示（转场页「演示」，6 个节目自动轮放）删掉；提示条：预览时显示本次效果名
    wire hint_eff = preview & ~transition_busy;

    assign layer_en           = display_valid & standby;
    assign layer_sel_en       = menu_visible & (page_r == 2'd2) & standby;
    assign status_osd_en      = 1'b0;          // R1.5b：旧 ASCII 状态 OSD 关掉，换成中文状态栏
    assign pipe_no_transition = cpr_active;
    // R7c-1 按键音：任意键按下就响（不管这一下有没有功能，让人知道按到了）；长按到点那一刻再响一次
    //   （K2 / K3 / K4 1 秒、K4 2 秒）。只用已寄存的单拍事件相或，不和页 / 急救状态组合（sd_card_clk 余量很紧）
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) key_tick <= 1'b0;
        else key_tick <= k1_press | k2_press_any | k3_press | k4_press | k2_hold | k3_hold | k4_hold | k4_hold2_w | fac_now | k1_hold_e;   // K1 满 1 秒也响（播放模式 = 频谱开关）
    end
    // 急救覆盖（R8-1a）：急救全程读 bank5（PIC6，左按压右 AED），缺失 / 读取失败 -> 黑底（文字照常叠加）。
    //   没出图时 reader 不开，画面本来就黑。原来 ① 读 PIC3（呼救图），新 PIC3 是「作品优势」，不再用
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            emg_ovr_en <= 1'b0;  emg_ovr_bank <= 3'd5;  emg_ovr_black <= 1'b0;
        end else begin
            emg_ovr_en    <= cpr_active;
            emg_ovr_bank  <= 3'd5;
            emg_ovr_black <= !emg_ok;
        end
    end
    assign bc_freeze       = ~disp;
    // 亮度 / 对比度（档位不变，R8-2 起在显示页调）：K1 单击 亮度 255 -> 192 -> 128 -> 64 -> 255；
    //   K2 单击 对比度 128 -> 192 -> 255 -> 64 -> 128；K3 单击 色彩 +1；K4 单击 字幕颜色 +1；K4 长按 轮播间隔 +1
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            menu_brightness <= 8'd255;
            menu_contrast   <= 8'd128;
            menu_sat        <= 2'd2;
            sub_color       <= 3'd0;
            auto_int        <= 3'd1;           // 3 秒
        end else if (fac_now) begin            // R8-4b：显示页 K1 长按 3 秒 = 恢复默认（按下那一刻的亮度 +1 被盖掉）
            menu_brightness <= 8'd255;
            menu_contrast   <= 8'd128;
            menu_sat        <= 2'd2;
            sub_color       <= 3'd0;
            auto_int        <= 3'd1;
        end else if (save_ld) begin            // R8-4a：开机套用存档
            menu_brightness <= save_dat[47:40];
            menu_contrast   <= save_dat[55:48];
            menu_sat        <= save_dat[57:56];
            sub_color       <= save_dat[66:64];
            auto_int        <= (save_dat[74:72] > 3'd5) ? 3'd1 : save_dat[74:72];
        end else if (disp) begin
            if (k3_click) menu_sat <= menu_sat + 2'd1;
            if (k4_click) sub_color <= sub_color + 3'd1;
            if (k4_hold)  auto_int <= (auto_int == 3'd5) ? 3'd0 : auto_int + 3'd1;
            if (k1_bri)                        // R10：松开时判断（< 1 秒），长按 1~3 秒松开 = 频谱开关
                case (menu_brightness)
                    8'd255:  menu_brightness <= 8'd192;
                    8'd192:  menu_brightness <= 8'd128;
                    8'd128:  menu_brightness <= 8'd64;
                    default: menu_brightness <= 8'd255;
                endcase
            if (k2_click)
                case (menu_contrast)
                    8'd128:  menu_contrast <= 8'd192;
                    8'd192:  menu_contrast <= 8'd255;
                    8'd255:  menu_contrast <= 8'd64;
                    default: menu_contrast <= 8'd128;
                endcase
        end
    end
    // ---------------- R8-4b：掉电保存（写回 SAVE.BIN） ----------------
    // 显示页 K1 长按 3 秒 = 恢复默认（单拍 fac_now），立即写卡
    // 显示页 K1 松开时：没满 3 秒 = 亮度（k1_bri）；满 3 秒已经恢复默认，松开不再动作
    // R11：频谱开关挪到播放模式 K1 按满 1 秒（viz_tog，和自动轮播共用 K1：满 1 秒就不算单击）
    reg  [11:0] k1_ms;
    reg         fac_now;
    reg         k1_lq, k1_lt3, k1_bri, viz_tog;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            k1_ms <= 12'd0;  fac_now <= 1'b0;
            k1_lq <= 1'b1;  k1_lt3 <= 1'b1;  k1_bri <= 1'b0;  viz_tog <= 1'b0;
        end else begin
            k1_lq   <= k1_level;
            k1_lt3  <= (k1_ms < 12'd3000);
            k1_bri  <= disp && display_valid && k1_level && !k1_lq && k1_lt3;
            viz_tog <= play && display_valid && k1_hold_e;
            fac_now <= disp && display_valid && !k1_level && ms_tick && (k1_ms == 12'd2999);
            if (k1_level || !disp)
                k1_ms <= 12'd0;
            else if (ms_tick && k1_ms != 12'd3000)
                k1_ms <= k1_ms + 12'd1;
        end
    end
    // R9 资源：急救记录（进交接页锁存用时 / 按压次数 / AED 时刻并立即写卡、开机提示"上次急救"）删掉，存档字节 16~24 写 0
    // 存档内容（格式见 doc/R8-4_方案.md 第 3 节）；当前图在自动轮播时也照存，只是轮播换图不触发写卡
    wire [2:0]  sv_pic  = cur_index;
    wire [4:0]  sv_flag = {m_flip, m_mirror, auto_on, m_show[1], stat_on};
    wire [87:0] sv_set  = {5'd0, sv_pic, 4'd0, m_vol, 4'd0, fx_speed_w, 4'd0, fx_effect_w, 5'd0, m_viz,
                           3'd0, sv_flag, 5'd0, auto_int, 5'd0, sub_color, 6'd0, menu_sat, menu_contrast, menu_brightness};   // 字节 5~15
    wire [71:0] sv_rec  = 72'd0;                                                                                         // 字节 16~24（原急救记录）
    // 第 31 字节（校验）由 sd_card_bmp 写卡时边发边算，这里填 0
    assign save_img = {8'd0, 48'd0, sv_rec, sv_set, 8'd1, "S", "R", "P", "C"};
    // 待机时任何按键按下 = 设置可能变了：停 3 秒（期间再按就重新计时）再写一次；切图（K2 / 缩略图确认）也会存当前图。
    //   R8-4b 资源：原来逐拍比较 47 位设置，改成看按键（时序拥塞）。急救中按键不算。
    //   恢复默认：计时直接跳到 2990ms，10ms 后写（默认值 2 拍后就稳定）
    reg         sv_dirty, fac_d, stby_q;
    reg  [11:0] sv_ms;
    always @(posedge clk or negedge rst_n_l) begin
        if (!rst_n_l) begin
            sv_dirty <= 1'b0;  sv_ms <= 12'd0;  save_req <= 1'b0;  fac_d <= 1'b0;  stby_q <= 1'b0;
        end else begin
            save_req <= 1'b0;
            fac_d    <= fac_now;
            stby_q   <= standby;
            if (!display_valid) begin
                sv_dirty <= 1'b0;
            end else if (fac_now || fac_d) begin   // fac_d：下一拍 key_tick 里也带着 fac_now（按键音），别把计时清零
                sv_dirty <= 1'b1;  sv_ms <= 12'd2990;
            end else if (key_tick && standby && stby_q) begin   // stby_q：结束急救那一下长按（key_tick 晚一拍）不算
                sv_dirty <= 1'b1;  sv_ms <= 12'd0;
            end else if (sv_dirty && standby) begin
                if (sv_ms == 12'd3000) begin
                    sv_dirty <= 1'b0;  save_req <= 1'b1;
                end else if (ms_tick)
                    sv_ms <= sv_ms + 12'd1;
            end
        end
    end

    assign pipe_brightness = (st == 3'd4) ? 8'd64 : cpr_active ? 8'd255 : menu_brightness;   // 交接页 PIC6 压暗到 1/4，突出文字
    assign pipe_contrast   = cpr_active ? 8'd128 : menu_contrast;
    assign pipe_sat        = cpr_active ? 2'd2 : menu_sat;

    page_menu_ctrl #(.CLKS_PER_MS(CLKS_PER_MS), .EXT_MS(EXT_MS)) u_menu (
        .ms_tick_in(ms_tick_in),
        .clk(clk), .rst_n(rst_n_m), .enable_in(display_valid & standby), .page_in(page_r),
        .k2_click_in(k2_click), .k2_hold_in(k2_hold), .k3_n(k3_level), .k4_n(k4_level),
        .setup_on(setup_on), .raw_page(raw_page), .auto_on(auto_on), .music_on(sw4_on),
        .cpr_st_in(st), .cpr_302_in(cpr_mode_302), .cpr_breath_in(cpr_breath), .cpr_cyc_in(cpr_cyc),
        .cpr_ssec_in(cpr_ssec), .cpr_brs_in(cpr_brs), .cpr_swap_in(cpr_swap), .cpr_intro_in(cpr_intro), .cpr_full_in(cpr_full),
        .cpr_grp_in(cpr_grp), .cpr_voice_in({~guide_ok, g_muted}), .viz_tog(viz_tog), .note_show(note_show),
        .cpr_tmr_in(cpr_timer_bcd), .cpr_cmp_in(cpr_comp_bcd), .cpr_aed_in(cpr_aed_time_bcd), .cpr_aseen_in(cpr_aed_seen),
        .next_hint(k2_next), .prev_hint(k2_prev), .eff_hint(hint_eff), .eff_hint_id(pipe_fx_effect),
        .demo_hint(1'b0), .demo_id(3'd0),
        .fault_code(fault_code), .fault_arg(fault_arg), .fault_tot(fault_tot), .tfok_hint(tfok_hint), .fault_show(fault_show),
        .sub_upd(sub_upd), .sub_rst(sub_rst), .sub_show(sub_show), .sub_mot(sub_mot),
        .save_ld(save_ld), .save_in(save_dat[127:80]),
        .fac_rst(fac_now), .wfail_hint(save_fail), .last_hint(1'b0), .last_in(32'd0),
        .bri_in(menu_brightness), .con_in(menu_contrast), .thumb_in(thumb_view),
        .sat_in(menu_sat), .scol_in(sub_color), .int_in(auto_int), .sub_tog(sub_tog), .stat_tog(stat_tog),
        .cur_idx_in(cur_index), .cur_wh_in(cur_wh), .img_cnt_in(img_found_count),
        .visible(menu_visible), .stat_on(stat_on), .menu_disp(menu_disp), .hint_show(hint_show), .hint_leave(hint_leave),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data),
        .vol_gain(vol_gain), .vw_viz(m_viz),
        .fx_effect(fx_effect_w), .fx_speed(fx_speed_w), .fx_mode(fx_mode_w), .fx_demo(), .fx_preview(fx_preview_w),
        .ly_sel(ly_sel), .ly_show(m_show), .ly_x(ly_x), .ly_y(ly_y), .ly_alpha(ly_alpha), .ly_z(ly_z), .ly_motion(m_motion),
        .vw_sx(vw_sx), .vw_sy(vw_sy), .vw_mirror(m_mirror), .vw_flip(m_flip), .vw_panx(vw_panx), .vw_pany(vw_pany),
        .vw_kenburns(m_kb), .vw_volume(m_vol)
    );

    // R5：画面变换参数。缩略图 / 急救 / 显示没打开时恒等
    wire [4:0] vw_sx, vw_sy;
    wire       vw_mirror, vw_flip, vw_kb;
    wire       m_mirror, m_flip, m_kb;
    wire [3:0] m_show;
    wire [7:0] m_motion;
    wire [2:0] m_viz;
    wire [3:0] m_vol;                    // R8-4b：存档用
    assign ly_show   = m_show;
    assign ly_motion = m_motion;
    assign vw_kb     = 1'b0;                 // R8-4b 资源：删推拉摇移
    assign vw_mirror = m_mirror;
    assign vw_flip   = m_flip;
    assign vw_viz    = m_viz;
    wire signed [5:0] vw_panx, vw_pany;
    geom_param #(.CLKS_PER_MS(CLKS_PER_MS), .W(IMG_W), .H(IMG_H)) u_geom (
        .clk(clk), .rst_n(rst_n_l), .enable(display_valid & standby & ~thumb_view),
        .sx_q(vw_sx), .sy_q(vw_sy), .mirror(vw_mirror), .flip(vw_flip), .panx(vw_panx), .pany(vw_pany),
        .kenburns(vw_kb),
        .stepx(geo_stepx), .startx(geo_startx), .stepy(geo_stepy), .starty(geo_starty),
        .mirror_o(geo_mirror), .flip_o(geo_flip)
    );
endmodule
