`timescale 1ns/1ps
`include "../user_source/hdl_source/include/text_ids.vh"  // TD 相对 td_project 目录；仿真加 -Isrc/td_project
`include "../user_source/hdl_source/include/ui_text.vh"   // R8-2：显示页的色彩 / 字幕颜色名（T_SATn / T_SCn 宏）放进变量字节

// R1 拨码功能页 + OSD 菜单控制（sd_card_clk 域）。按键表见 doc/作品流程与开发路线.md 与 R1 确认稿：
//   功能页 page：0 PLAY 播放 / 1 TRANS 转场 / 2 LAYER 图层 / 3 VIEW 画面与声音（SW3 SW2，ui_key_router 消抖后给出）
//   page 1~3：K2 单击 = 下一项，K2 长按 = 上一项（循环）；K3 = 加 / 执行，K4 = 减；K3/K4 按住 0.5 秒后每 0.1 秒连续
//   page 0：不弹菜单，切到这页时闪 2 秒 "PLAY"；按键由 ui_key_router 按原播放功能路由
// R1.5b 文字全部中文（include/ui_text.vh），每 1024 拍逐字节写进 cn_text_overlay 的文字 RAM：
//   状态栏 2 行 × 24 格（常驻：轮播 / 音乐，亮度 / 对比度）、设置菜单 2 行 × 24 格（SW1 开着就一直显示）、
//   中间提示条 24 格（hint_show 1 秒 + hint_leave 0.25 秒上滑淡出）。
// 本轮真正生效的只有 VOLUME 音量（SW4 关 = 0）、VIZ 关闭波形；其余参数先保存和显示，R2~R6 接上。
// 提示条（后发生的顶掉前一个）：轮播 / 背景音乐 / 设置模式 开关、SW1 关时拨 SW2/SW3、亮度 / 对比度档位、进出缩略图、
//   设置模式下切页（播放页 / 转场设置 / 图层设置 / 画面与声音设置）、K2 下一张 / 上一张、转场预览 / 演示时的效果名。
// R8-0b：固定文字全部放进文字 ROM（io/text_rom.v，tools/gen_cn_font.py 生成 text_rom.hex + include/text_ids.vh）。
//   每 1024 拍的第 1004~1010 拍做一次快照：每行只算"用 ROM 里哪段模板"（12 位起始地址）+ 14 个变量字节（数字 / 时间），
//   第 1018 拍起生成器逐字节读 ROM、把占位符换成变量字节或效果名词表的字节，按原来的节奏写进文字 RAM（写出的内容和 R8-0a 逐字节相同）。
//   「画面与声音」页去掉了从 R1 起就没做的「音画测试」项（11 项 -> 10 项）。
// R8-2：页 00（SW1 开）= 显示页，不是菜单：K1 亮度 / K2 对比度 / K3 色彩 / K4 单击字幕颜色、长按轮播间隔（ui_key_router 里改值），
//   菜单框常驻「K1亮度4  K2对比度2」/「K3色彩标准 K4字幕黄/15秒」，改了哪个提示条显示哪个。播放模式 K3 单击 = 字幕开 / 关（sub_tog）。
//   转场页删「预览」项（改成转场页 K1），5 项 -> 4 项；可视化删示波器：关 / 波形 / 频谱 / 音量表。
// R8-2b：上电字幕关、状态栏关；播放模式 K3 长按 = 状态栏开 / 关（stat_tog，急救中 cn_text_overlay 强制显示）；
//   状态栏第三行「色彩标准 字幕黄 间隔15秒」（生成器第 7 行，写文字 RAM 192~215，变量字节单独一组 vb7）；
//   显示页菜单框只写按键名（两行白色，cn_text_overlay 按 menu_disp 选色）；轮播间隔 6 档 1 / 3 / 5 / 8 / 10 / 15 秒。
// R10：上电 / 恢复默认 可视化 = 关，开机不从存档恢复可视化；viz_tog = 频谱 开 / 关（R11 起是播放模式 K1 按满 1 秒）；
//   可视化只剩 关 / 频谱（波形、音量表删掉），转场页删「演示」（一键演示删掉，fx_demo 恒 0）。字幕层默认底部居中 (64,440)、静止。
// R11（doc/R11_方案.md）：急救底栏 / 右上要点按新时间轴（cmom 14 个时刻）；正中黄框 note_show（① 讲完「准备好后按K3开始按压」/
//   ②「到了两分钟，建议换人」），文字借故障条那一行（真有故障时故障条优先）；删 7A 实测频率（急救中状态栏只 3 行）；
//   转场速度 8 -> 1 / 1 -> 8 循环；轮播 4 张，片内字幕 4 条。
// R12（doc/R12_方案.md）：换人提示 ② ③ 都显示（右上要点只在 ② 换成换人要领）；开机读图时正中黄框「正在读取图片 n/m」
//   （fault_code 14，n = V14、m = V13，按黄框画、不算故障）。
module page_menu_ctrl #(
    parameter integer CLKS_PER_MS = 100_000,
    parameter integer EXT_MS      = 0,        // R12b：1 = 用 ms_tick_in（顶层共用的 1ms 节拍）
    parameter integer SHOW_MS     = 5000,     // 菜单操作后显示多久
    parameter integer HINT_MS     = 1000,     // 提示条停留
    parameter integer LEAVE_MS    = 250       // 提示条上滑淡出
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         ms_tick_in,      // R12b：EXT_MS = 1 时用
    input  wire         enable_in,       // display_valid && 不在急救中
    input  wire [1:0]   page_in,
    input  wire         k2_click_in,     // 已消抖单拍（sd_card_bmp）
    input  wire         k2_hold_in,
    input  wire         k3_n,            // R8-0a：已消抖电平（ui_key_router 给出），本模块做单击 + 连续
    input  wire         k4_n,
    input  wire         setup_on,        // SW1（消抖后）
    input  wire [1:0]   raw_page,        // SW3 SW2 原样（SW1 关时 page_in 恒为 0，提示用）
    input  wire         auto_on,         // 自动轮播开关状态
    input  wire         music_on,        // SW4（消抖后）
    input  wire [7:0]   bri_in,          // bc_menu_controller 亮度 / 对比度（状态栏和提示条显示档位）
    input  wire [7:0]   con_in,
    input  wire [1:0]   sat_in,          // R8-2 显示页：色彩 0 黑白 1 淡 2 标准 3 鲜艳
    input  wire [2:0]   scol_in,         //   片内字幕颜色 0~7
    input  wire [2:0]   int_in,          //   轮播间隔 0~5 = 1 / 3 / 5 / 8 / 10 / 15 秒（R8-2b 加 1 秒）
    input  wire         sub_tog,         //   单拍：播放模式 K3 单击，字幕层 显示 取反
    input  wire         stat_tog,        //   R8-2b 单拍：播放模式 K3 长按，状态栏开 / 关
    input  wire         thumb_in,        // 缩略图模式
    input  wire [2:0]   cur_idx_in,      // 当前显示第几张（已同步到本时钟域）
    input  wire [21:0]  cur_wh_in,       // R8-5c：当前图原始 {宽, 高}（sd_card_bmp 查表，同时钟域）
    input  wire [2:0]   img_cnt_in,      // 共几张
    // R7a 急救（cpr_flow_ctrl）：急救中状态栏换成计时 / 计数，提示条常驻显示当前步骤
    input  wire [2:0]   cpr_st_in,       // 0 待机 1 呼救 2 按压（等 AED）3 AED 4 交接
    input  wire [6:0]   cpr_ssec_in,     // R9：本部分已过秒数（① 时间轴 / ③ 5 秒后换句）
    input  wire [3:0]   cpr_brs_in,      //   人工呼吸第几秒 0~9（6 秒起是第 2 口，8 秒起「继续准备按压」）
    input  wire         cpr_swap_in,     //   R11：正中提示「到了两分钟，建议换人」
    input  wire         cpr_intro_in,    //   ② 开头讲要领 / 「继续按压」
    input  wire         cpr_full_in,     //   ② 这次是完整要领
    input  wire [7:0]   cpr_grp_in,      //   第几组 BCD
    input  wire [1:0]   cpr_voice_in,    //   {没有 GUIDE.WAV, 静音}
    input  wire         cpr_302_in,
    input  wire         cpr_breath_in,
    input  wire [4:0]   cpr_cyc_in,
    input  wire [15:0]  cpr_tmr_in,      // mm:ss BCD
    input  wire [15:0]  cpr_cmp_in,      // 按压拍数 BCD
    input  wire [15:0]  cpr_aed_in,      // 第一次 AED 的时刻 mm:ss BCD
    input  wire         viz_tog,         // 单拍：频谱 开 / 关（R11：播放模式 K1 按满 1 秒）
    input  wire         cpr_aseen_in,
    input  wire         next_hint,       // 单拍：K2 下一张 / 上一张
    input  wire         prev_hint,
    input  wire         eff_hint,        // 单拍：本次转场显示效果名（预览 / 演示）
    input  wire [3:0]   eff_hint_id,
    input  wire         demo_hint,       // 单拍：一键演示换节目
    input  wire [2:0]   demo_id,
    input  wire [3:0]   fault_code,      // R4：tf_fault_monitor
    input  wire [2:0]   fault_arg,
    input  wire [2:0]   fault_tot,       // R12：开机读图提示的总张数（V13）
    input  wire         tfok_hint,       // 单拍：拔卡后已恢复
    // R8-1c 串口字幕（uart_subtitle，单拍）：替换成功时把字幕层的 显示 / 运动 改成电脑发来的值，并弹提示条
    input  wire         sub_upd,
    input  wire         sub_rst,
    input  wire         sub_show,
    input  wire [1:0]   sub_mot,
    input  wire         save_ld,         // R8-4a：单拍，开机套用存档
    input  wire [47:0]  save_in,         //   存档字节 10~15：{当前图, 音量, 转场速度, 转场效果, 可视化, 开关位}
    input  wire         fac_rst,         // R8-4b：单拍，显示页 K1 长按 3 秒 = 恢复默认设置
    input  wire         wfail_hint,      //   单拍：存档写卡失败
    input  wire         last_hint,       //   单拍：开机显示上次急救记录
    input  wire [31:0]  last_in,         //   {按压次数, 总用时 mm:ss}（BCD）

    output wire         visible,         // 设置菜单框（R7b-2：急救中强制显示，内容换成急救步骤）
    output reg          stat_on,         // R8-2b 状态栏开（上电关；急救中 cn_text_overlay 自己强制显示）
    output reg          menu_disp,       // R8-2b 菜单框是显示页（两行都白色），寄存输出
    output reg          hint_show,       // 寄存输出（跨到 video_clk 域，不能带组合毛刺）
    output reg          hint_leave,
    output reg          fault_show,      // 正中故障条（寄存输出）
    output reg          note_show,       // R11：急救正中黄框（寄存输出；文字和故障条同一行，有故障时不显示）
    output reg          txt_we,          // 文字 RAM 写口
    output reg  [7:0]   txt_addr,        // 0~119 界面文字 / 224~247 故障条（cn_text_overlay），128~191 字幕条（layer_compositor）
    output reg  [10:0]  txt_data,        // {右半, 页[1:0], 码}（R8-1b：汉字 3 页 384 个）

    // ---- 生效的参数 ----
    output reg  [7:0]   vol_gain,        // 0~255（VOLUME 0~100% 查表）
    output reg  [2:0]   vw_viz,          // 0 OFF 1 WAVE 2 BAR 3 SCOPE 4 METER

    // ---- R2~R6 用（本轮先保存）----
    output reg  [3:0]   fx_effect,
    output reg  [3:0]   fx_speed,
    output reg  [1:0]   fx_mode,
    output reg          fx_demo,
    output reg          fx_preview,      // 单拍（R8-2 起菜单里没有「预览」项，恒 0；预览改成转场页 K1，在 ui_key_router 里）
    output reg  [1:0]   ly_sel,          // 当前选中的图层（图层页画虚线框）
    output reg  [3:0]   ly_show,
    output reg  [27:0]  ly_x,            // 4 × 7 位，单位 8 像素（layer n 在 [7n+6:7n]）
    output reg  [23:0]  ly_y,            // 4 × 6 位，单位 8 像素
    output reg  [15:0]  ly_alpha,        // 4 × 4 位，0~10 = 0~100%
    output reg  [7:0]   ly_z,            // 4 × 2 位，0 最下层 3 最上层
    output reg  [7:0]   ly_motion,       // 4 × 2 位，0 OFF 1 BOUNCE 2 SCROLL
    output reg  [4:0]   vw_sx,           // 1~16 = 0.25~4.00 倍
    output reg  [4:0]   vw_sy,
    output reg          vw_mirror,
    output reg          vw_flip,
    output reg  signed [5:0] vw_panx,    // -20~20，单位 16 像素
    output reg  signed [5:0] vw_pany,    // -15~15
    output reg          vw_kenburns,
    output reg  [3:0]   vw_volume        // 0~10
);
    localparam [1:0] P_PLAY = 2'd0, P_TRANS = 2'd1, P_LAYER = 2'd2, P_VIEW = 2'd3;
    localparam [3:0] N_TRANS = 4'd3, N_LAYER = 4'd8, N_VIEW = 4'd9;   // R8-4b 资源：画面页删「推拉摇移」（10 -> 9 项）；R10：转场页删「演示」（4 -> 3 项）

    // ---------------- K3 / K4：单击 + 连续 ----------------
    wire inc_w, dec_w;
    // R8-5a 资源：两个连续键共用一个 1ms 节拍；R12b 资源：EXT_MS = 1 时用顶层共用的 1ms 节拍 ms_tick_in（本地再寄存一拍，跨模块长线留一整拍），不再自己分频
    reg [16:0] ms_div;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_div <= 17'd0;  ms_tick <= 1'b0;
        end else if (EXT_MS) begin
            ms_tick <= ms_tick_in;
        end else begin
            ms_tick <= (ms_div == CLKS_PER_MS - 1);
            ms_div  <= (ms_div == CLKS_PER_MS - 1) ? 17'd0 : ms_div + 17'd1;
        end
    end
    key_repeat u_k3 (.clk(clk), .rst_n(rst_n), .tick(ms_tick), .key_n(k3_n), .step(inc_w));
    key_repeat u_k4 (.clk(clk), .rst_n(rst_n), .tick(ms_tick), .key_n(k4_n), .step(dec_w));

    // 输入全部先寄存一拍：拨码消抖 / 按键事件到参数更新之间断开（否则 sd_card_clk 上 -2.5ns）
    reg       enable, k2_click, k2_hold, inc, dec;
    reg [1:0] page, rpage, rpage_q;
    reg       setup_s, setup, setup_q, aut, aut_q, mus, mus_q, thb, thb_q;
    reg [7:0] bri, bri_q, con, con_q;
    reg [1:0] sat, sat_q;
    reg [2:0] scl, scl_q, itv, itv_q;
    reg       stog, ttog, vtog;
    reg [2:0] cidx;
    reg [2:0] cnt;
    // R8-5b 时序：提示事件（单拍）也先寄存（原来 display_valid -> 演示 / 转场事件门控 -> hint 选择一拍，-1.9ns），提示晚 10ns 出现
    reg       e_next, e_prev, e_demo, e_tfok, e_eff;
    reg       e_frst, e_wfail;              // R8-4b（R9 资源：开机"上次急救"提示删掉，last_hint / last_in 不再使用）
    reg [3:0]  e_frst_d;
    reg [2:0] e_did;
    reg [3:0] e_eid;
    always @(posedge clk) begin
        e_next <= next_hint;  e_prev <= prev_hint;  e_demo <= demo_hint;  e_did <= demo_id;
        e_tfok <= tfok_hint;  e_eff <= eff_hint;  e_eid <= eff_hint_id;
        e_frst <= fac_rst;  e_wfail <= wfail_hint;
        e_frst_d <= {e_frst_d[2:0], e_frst};
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable <= 1'b0;  page <= 2'd0;  k2_click <= 1'b0;  k2_hold <= 1'b0;  inc <= 1'b0;  dec <= 1'b0;
            rpage <= 2'd0;  rpage_q <= 2'd0;  setup_s <= 1'b0;  setup <= 1'b0;  setup_q <= 1'b0;
            aut <= 1'b0;  aut_q <= 1'b0;  mus <= 1'b0;  mus_q <= 1'b0;  thb <= 1'b0;  thb_q <= 1'b0;
            bri <= 8'd255;  bri_q <= 8'd255;  con <= 8'd128;  con_q <= 8'd128;  cidx <= 3'd0;  cnt <= 3'd0;
            sat <= 2'd2;  sat_q <= 2'd2;  scl <= 3'd0;  scl_q <= 3'd0;  itv <= 3'd1;  itv_q <= 3'd1;  stog <= 1'b0;  ttog <= 1'b0;  vtog <= 1'b0;
        end else begin
            enable <= enable_in;  page <= page_in;  k2_click <= k2_click_in;  k2_hold <= k2_hold_in;
            inc <= inc_w;  dec <= dec_w;
            // setup 多打一拍，和 page（ui_key_router page_r 一拍 + 这里一拍）对齐，下面只用寄存后的 page
            rpage <= raw_page;  rpage_q <= rpage;  setup_s <= setup_on;  setup <= setup_s;  setup_q <= setup;
            aut <= auto_on;  aut_q <= aut;  mus <= music_on;  mus_q <= mus;  thb <= thumb_in;  thb_q <= thb;
            bri <= bri_in;  bri_q <= bri;  con <= con_in;  con_q <= con;  cidx <= cur_idx_in;  cnt <= img_cnt_in;
            sat <= sat_in;  sat_q <= sat;  scl <= scol_in;  scl_q <= scl;  itv <= int_in;  itv_q <= itv;  stog <= sub_tog;  ttog <= stat_tog;
            vtog <= viz_tog;
        end
    end

    // 提示码
    localparam [5:0] H_NONE = 6'd0, H_AUTO_ON = 6'd1, H_AUTO_OFF = 6'd2, H_MUS_ON = 6'd3, H_MUS_OFF = 6'd4,
                     H_SET_ON = 6'd5, H_SET_OFF = 6'd6, H_SW1 = 6'd7,
                     H_BRI1 = 6'd8, H_BRI2 = 6'd9, H_BRI3 = 6'd10, H_BRI4 = 6'd11,
                     H_CON1 = 6'd12, H_CON2 = 6'd13, H_CON3 = 6'd14, H_CON4 = 6'd15,
                     H_THUMB = 6'd16, H_FULL = 6'd17, H_PLAY = 6'd18, H_TRANS = 6'd19, H_LAYER = 6'd20, H_VIEW = 6'd21,
                     H_NEXT = 6'd22, H_PREV = 6'd23, H_EFF = 6'd24, H_TFOK = 6'd25, H_DEMO = 6'd26,
                     H_SUBOK = 6'd27, H_SUBRST = 6'd28, H_SAT = 6'd29, H_SCOL = 6'd30, H_INT = 6'd31,
                     H_SUB0 = 6'd32, H_SUB1 = 6'd33, H_STAT0 = 6'd34, H_STAT1 = 6'd35,
                     H_FRST = 6'd36, H_WFAIL = 6'd37, H_LAST = 6'd38,          // R8-4b
                     H_VIZ0 = 6'd39, H_VIZ1 = 6'd40;                           // R10 频谱 关闭 / 开启
    reg [3:0]  hint_eff;
    reg [5:0]  hint;
    reg [17:0] hint_cnt;        // R8-5b 资源：单位 1ms（原来 32 位数时钟）
    reg        hint_kick;
    // 急救中（含交接页）提示条常驻显示步骤（hint_cnt 在急救中被清零，不会和普通提示冲突）
    reg        cpr_on;
    reg [2:0]  cst;
    reg        c302, cbr, caseen;
    reg [4:0]  ccyc;
    reg [15:0] ctmr, ccmp, caed;
    // R9：底栏 / 右上要点按「时刻」选（cmom），cdig = 底栏里的一位数字（① 倒数 / 人工呼吸第几口）
    // R11 时刻（和 guide_seq 的语音同一秒换）：① 0 1Z 有人晕倒 / 2 1A 拍肩 / 5 1B 看胸口（7~11 秒倒数 5~1）/ 12 1C 打 120 / 17 1D 下面进行CPR
    //   ② 准备 2I 要领（第一次 / K1 重讲，9 秒起 2S 开始按压）/ 2R 继续按压（从 ③ 回来）/ 2C 按压 nn/30 / 人工呼吸 BR（0~7 秒）、BE（8 秒起 继续准备按压）
    localparam [3:0] CM_1Z = 4'd0, CM_1A = 4'd1, CM_1B = 4'd2, CM_1C = 4'd3, CM_1D = 4'd4, CM_2I = 4'd5, CM_2S = 4'd6,
                     CM_2R = 4'd7, CM_2C = 4'd8, CM_BR = 4'd9, CM_BE = 4'd10, CM_3A = 4'd11, CM_3B = 4'd12, CM_END = 4'd13;
    reg [3:0]  cmom;
    reg [7:0]  cdig, cgrp;
    reg [1:0]  cvoi;
    reg [1:0]  cnote;                   // R11 正中黄框：0 无 / 1 准备好后按K3 / 2 到了两分钟
    reg        cswap;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpr_on <= 1'b0;  cst <= 3'd0;  c302 <= 1'b0;  cbr <= 1'b0;  caseen <= 1'b0;  ccyc <= 5'd0;
            ctmr <= 16'd0;  ccmp <= 16'd0;  caed <= 16'd0;  cmom <= CM_END;  cdig <= " ";  cgrp <= 8'h01;  cvoi <= 2'd0;
            cnote <= 2'd0;  cswap <= 1'b0;
        end else begin
            cpr_on <= (cpr_st_in != 3'd0);  cst <= cpr_st_in;  c302 <= cpr_302_in;  cbr <= cpr_breath_in;
            caseen <= cpr_aseen_in;  ccyc <= cpr_cyc_in;  ctmr <= cpr_tmr_in;  ccmp <= cpr_cmp_in;  caed <= cpr_aed_in;
            cgrp <= cpr_grp_in;  cvoi <= cpr_voice_in;
            cswap <= (cpr_st_in == 3'd2) && cpr_swap_in;
            cnote <= (cpr_st_in == 3'd1 && cpr_ssec_in >= 7'd20) ? 2'd1 :
                     ((cpr_st_in == 3'd2 || cpr_st_in == 3'd3) && cpr_swap_in) ? 2'd2 : 2'd0;   // R12：③ AED 分析时也提示换人
            cdig <= " ";
            case (cpr_st_in)
                3'd1: if (cpr_ssec_in < 7'd2)       cmom <= CM_1Z;
                      else if (cpr_ssec_in < 7'd5)  cmom <= CM_1A;
                      else if (cpr_ssec_in < 7'd12) begin
                          cmom <= CM_1B;
                          case (cpr_ssec_in)                 // 倒数按秒查表（和语音「五~一」同一秒）
                              7'd7:    cdig <= "5";
                              7'd8:    cdig <= "4";
                              7'd9:    cdig <= "3";
                              7'd10:   cdig <= "2";
                              7'd11:   cdig <= "1";
                              default: cdig <= " ";
                          endcase
                      end else if (cpr_ssec_in < 7'd17) cmom <= CM_1C;
                      else                           cmom <= CM_1D;
                3'd2: if (cpr_breath_in) begin
                          cmom <= (cpr_brs_in >= 4'd8) ? CM_BE : CM_BR;
                          cdig <= (cpr_brs_in >= 4'd6) ? "2" : "1";
                      end else if (cpr_intro_in)     cmom <= !cpr_full_in ? CM_2R : (cpr_ssec_in >= 7'd9) ? CM_2S : CM_2I;
                      else                           cmom <= CM_2C;
                3'd3: cmom <= (cpr_ssec_in < 7'd5) ? CM_3A : CM_3B;
                default: cmom <= CM_END;
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hint_show <= 1'b0;  hint_leave <= 1'b0;
        end else begin
            hint_show  <= cpr_on || (hint_cnt > LEAVE_MS);
            hint_leave <= !cpr_on && (hint_cnt != 0) && !(hint_cnt > LEAVE_MS);
        end
    end
    localparam integer HINT_TOTAL = HINT_MS + LEAVE_MS;

    reg [3:0] it_trans, it_layer, it_view;
    reg [1:0] page_q;
    assign visible = (enable && setup) || cpr_on;   // 设置模式开着就一直显示；急救中显示急救步骤
    always @(posedge clk or negedge rst_n)
        if (!rst_n) menu_disp <= 1'b0;
        else        menu_disp <= enable && setup && (page == P_PLAY) && !cpr_on;

    wire in_menu = enable && (page != P_PLAY);
    wire [3:0] n_items = (page == P_TRANS) ? N_TRANS : (page == P_LAYER) ? N_LAYER : N_VIEW;
    wire [3:0] item    = (page == P_TRANS) ? it_trans : (page == P_LAYER) ? it_layer : it_view;

    function [7:0] gain_of;
        input [3:0] v;
        begin
            case (v)
                4'd0: gain_of = 8'd0;    4'd1: gain_of = 8'd26;   4'd2: gain_of = 8'd51;
                4'd3: gain_of = 8'd77;   4'd4: gain_of = 8'd102;  4'd5: gain_of = 8'd128;
                4'd6: gain_of = 8'd153;  4'd7: gain_of = 8'd179;  4'd8: gain_of = 8'd204;
                4'd9: gain_of = 8'd230;  default: gain_of = 8'd255;
            endcase
        end
    endfunction

    function [3:0] lv4;                 // 亮度 255/192/128/64 -> 4/3/2/1；对比度 64/128/192/255 -> 1/2/3/4
        input [7:0] v;
        lv4 = (v >= 8'd224) ? 4'd4 : (v >= 8'd160) ? 4'd3 : (v >= 8'd96) ? 4'd2 : 4'd1;
    endfunction

    // 当前选中图层的字段
    wire [6:0] sel_x     = ly_x[ly_sel*7 +: 7];
    wire [5:0] sel_y     = ly_y[ly_sel*6 +: 6];
    wire [3:0] sel_alpha = ly_alpha[ly_sel*4 +: 4];
    wire [1:0] sel_z     = ly_z[ly_sel*2 +: 2];
    wire [1:0] sel_mot   = ly_motion[ly_sel*2 +: 2];

    integer j;
    task layer_defaults;      // 图层 n 的默认位置 / 设置
        input [1:0] n;
        begin
            case (n)
                2'd0: begin ly_x[0*7 +: 7] <= 7'd66; ly_y[0*6 +: 6] <= 6'd7;  ly_alpha[0*4 +: 4] <= 4'd10; ly_motion[0*2 +: 2] <= 2'd0; ly_show[0] <= 1'b1; end  // LOGO 右上 (528,56)
                2'd1: begin ly_x[1*7 +: 7] <= 7'd8;  ly_y[1*6 +: 6] <= 6'd55; ly_alpha[1*4 +: 4] <= 4'd8;  ly_motion[1*2 +: 2] <= 2'd0; ly_show[1] <= 1'b0; end  // SUB 底部居中静止 (64,440)（R10），R8-2b 默认关
                2'd2: begin ly_x[2*7 +: 7] <= 7'd62; ly_y[2*6 +: 6] <= 6'd13; ly_alpha[2*4 +: 4] <= 4'd10; ly_motion[2*2 +: 2] <= 2'd0; ly_show[2] <= 1'b0; end  // PIP 右侧 (496,104)
                default: begin ly_x[3*7 +: 7] <= 7'd8; ly_y[3*6 +: 6] <= 6'd50; ly_alpha[3*4 +: 4] <= 4'd10; ly_motion[3*2 +: 2] <= 2'd0; ly_show[3] <= 1'b1; end // WAVE (64,400)
            endcase
        end
    endtask

    task view_defaults;
        begin
            vw_sx <= 5'd4;  vw_sy <= 5'd4;  vw_mirror <= 1'b0;  vw_flip <= 1'b0;
            vw_panx <= 6'sd0;  vw_pany <= 6'sd0;  vw_kenburns <= 1'b0;
            vw_viz <= 3'd0;  vw_volume <= 4'd6;      // R10：可视化默认关
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            it_trans <= 4'd0;  it_layer <= 4'd0;  it_view <= 4'd0;
            ly_sel <= 2'd0;  page_q <= 2'd0;
            fx_effect <= 4'd0;  fx_speed <= 4'd3;  fx_mode <= 2'd0;  fx_demo <= 1'b0;  fx_preview <= 1'b0;
            ly_show <= 4'b1001;                      // R8-2b：字幕默认关（K3 单击打开）
            stat_on <= 1'b0;                         // R8-2b：状态栏默认关（K3 长按打开）
            ly_x <= {7'd8, 7'd62, 7'd8, 7'd66};        // R10：字幕 x = 64（512 宽居中）
            ly_y <= {6'd50, 6'd13, 6'd55, 6'd7};
            ly_alpha <= {4'd10, 4'd10, 4'd8, 4'd10};
            ly_z <= {2'd0, 2'd1, 2'd2, 2'd3};          // LOGO 最上，WAVE 最下
            ly_motion <= {2'd0, 2'd0, 2'd0, 2'd0};     // R10：字幕默认静止（原来滚动）
            view_defaults;
            hint <= H_NONE;  hint_cnt <= 18'd0;  hint_eff <= 4'd0;  hint_kick <= 1'b0;
            vol_gain <= 8'd0;
        end else begin
            fx_preview <= 1'b0;
            hint_kick  <= 1'b0;
            page_q <= page;
            vol_gain <= mus ? gain_of(vw_volume) : 8'd0;

            if (hint_cnt != 0 && ms_tick)
                hint_cnt <= hint_cnt - 18'd1;


            // 提示条（同一拍多个事件时后写的优先；SW1 拨动时页号同一拍变化，"设置模式 开启 / 关闭" 优先于页名）
            if (enable) begin
                if (e_next || e_prev) begin
                    hint <= e_next ? H_NEXT : H_PREV;  hint_kick <= 1'b1;
                end
                if (e_tfok) begin
                    hint <= H_TFOK;  hint_kick <= 1'b1;
                end
                if (e_wfail) begin
                    hint <= H_WFAIL;  hint_kick <= 1'b1;
                end

                if (sub_upd || sub_rst) begin
                    hint <= sub_upd ? H_SUBOK : H_SUBRST;  hint_kick <= 1'b1;
                end
                if (e_eff) begin
                    hint <= H_EFF;  hint_eff <= e_eid;  hint_kick <= 1'b1;
                end
                if (thb != thb_q) begin
                    hint <= thb ? H_THUMB : H_FULL;  hint_kick <= 1'b1;
                end
                if (bri != bri_q) begin
                    hint <= H_BRI1 + {2'd0, lv4(bri)} - 6'd1;  hint_kick <= 1'b1;
                end
                if (con != con_q) begin
                    hint <= H_CON1 + {2'd0, lv4(con)} - 6'd1;  hint_kick <= 1'b1;
                end
                if (sat != sat_q) begin
                    hint <= H_SAT;  hint_kick <= 1'b1;
                end
                if (scl != scl_q) begin
                    hint <= H_SCOL;  hint_kick <= 1'b1;
                end
                if (itv != itv_q) begin
                    hint <= H_INT;  hint_kick <= 1'b1;
                end
                if (stog) begin
                    hint <= ly_show[1] ? H_SUB0 : H_SUB1;  hint_kick <= 1'b1;   // 本拍取反后的状态
                end
                if (ttog) begin
                    hint <= stat_on ? H_STAT0 : H_STAT1;  hint_kick <= 1'b1;
                end
                if (vtog) begin
                    hint <= (vw_viz == 3'd0) ? H_VIZ1 : H_VIZ0;  hint_kick <= 1'b1;   // 本拍切换后的状态
                end
                if (page != page_q) begin
                    hint <= (page == P_PLAY) ? H_PLAY : (page == P_TRANS) ? H_TRANS : (page == P_LAYER) ? H_LAYER : H_VIEW;
                    hint_kick <= 1'b1;
                end
                if (aut != aut_q) begin
                    hint <= aut ? H_AUTO_ON : H_AUTO_OFF;  hint_kick <= 1'b1;
                end
                if (mus != mus_q) begin
                    hint <= mus ? H_MUS_ON : H_MUS_OFF;  hint_kick <= 1'b1;
                end
                if (setup != setup_q) begin
                    hint <= setup ? H_SET_ON : H_SET_OFF;  hint_kick <= 1'b1;
                end
                if (!setup && rpage != rpage_q && rpage != P_PLAY) begin
                    hint <= H_SW1;  hint_kick <= 1'b1;
                end
                if (e_frst_d[3]) begin               // R8-4b：恢复默认晚 4 拍、放最后（各项值变化的提示晚 1~2 拍才出，不能盖掉这条）
                    hint <= H_FRST;  hint_kick <= 1'b1;
                end
            end else
                hint_cnt <= 18'd0;                 // 急救 / 未显示：提示条立即撤
            // R8-5a 时序：十几个事件 -> hint_cnt 使能一拍走不完（-0.5ns），事件先寄存成 hint_kick，下一拍再装载（晚 10ns 无影响）
            if (hint_kick && enable)
                hint_cnt <= HINT_TOTAL;


            if (sub_upd) begin                     // 串口字幕：字幕层 显示 / 运动（菜单里看到的就是新值）
                ly_show[1] <= sub_show;  ly_motion[1*2 +: 2] <= sub_mot;
            end
            if (enable && stog)                    // R8-2 播放模式 K3：字幕开 / 关（和图层页「字幕 显示」是同一个值）
                ly_show[1] <= ~ly_show[1];
            if (enable && ttog)                    // R8-2b 播放模式 K3 长按：状态栏开 / 关
                stat_on <= ~stat_on;
            if (enable && vtog)                    // 频谱 开 / 关（R11：播放模式 K1 按满 1 秒）
                vw_viz <= (vw_viz == 3'd0) ? 3'd2 : 3'd0;
            if (fac_rst) begin                     // R8-4b：恢复默认（和上电一样；图层位置 / 转场模式不在存档里，不动）
                stat_on    <= 1'b0;
                ly_show[1] <= 1'b0;
                fx_effect  <= 4'd0;
                fx_speed   <= 4'd3;
                view_defaults;
            end
            if (save_ld) begin                     // R8-4a：开机套用存档（加载图片前，菜单还没启用）
                stat_on    <= save_in[0];
                ly_show[1] <= save_in[1];
                vw_mirror  <= save_in[3];
                vw_flip    <= save_in[4];
                // R10：可视化不恢复（每次上电都是关，演示时手动打开）
                fx_effect  <= save_in[19:16];          // R12c：0~15 都有效（14 / 15 = 推移）
                fx_speed   <= (save_in[27:24] == 4'd0 || save_in[27:24] > 4'd8) ? 4'd3 : save_in[27:24];
                vw_volume  <= (save_in[35:32] > 4'd10) ? 4'd6 : save_in[35:32];
            end

            // ---- K2：选项目 ----
            if (in_menu && k2_click) begin
                case (page)
                    P_TRANS: it_trans <= (it_trans == N_TRANS - 1) ? 4'd0 : it_trans + 4'd1;
                    P_LAYER: it_layer <= (it_layer == N_LAYER - 1) ? 4'd0 : it_layer + 4'd1;
                    default: it_view  <= (it_view  == N_VIEW  - 1) ? 4'd0 : it_view  + 4'd1;
                endcase
            end else if (in_menu && k2_hold) begin
                case (page)
                    P_TRANS: it_trans <= (it_trans == 0) ? N_TRANS - 1 : it_trans - 4'd1;
                    P_LAYER: it_layer <= (it_layer == 0) ? N_LAYER - 1 : it_layer - 4'd1;
                    default: it_view  <= (it_view  == 0) ? N_VIEW  - 1 : it_view  - 4'd1;
                endcase
            end

            // ---- K3 加 / K4 减 ----
            if (in_menu && (inc ^ dec)) begin
                case (page)
                    P_TRANS: case (it_trans)
                        4'd0: fx_effect <= inc ? fx_effect + 4'd1 : fx_effect - 4'd1;   // R12c：16 种，0 ~ 15 循环
                        4'd1: fx_speed  <= inc ? ((fx_speed >= 4'd8) ? 4'd1 : fx_speed + 4'd1)      // R11：到 8 再加回 1，到 1 再减回 8
                                               : ((fx_speed <= 4'd1) ? 4'd8 : fx_speed - 4'd1);
                        default: fx_mode <= inc ? ((fx_mode == 2'd2) ? 2'd0 : fx_mode + 2'd1)
                                                : ((fx_mode == 2'd0) ? 2'd2 : fx_mode - 2'd1);   // R10：「演示」项删掉，fx_demo 恒 0
                    endcase
                    P_LAYER: case (it_layer)
                        // R8-4b 资源：删画中画（图层 2），选择只在 台标 / 字幕 / 波形 之间转
                        4'd0: ly_sel <= inc ? ((ly_sel == 2'd1) ? 2'd3 : ly_sel + 2'd1) : ((ly_sel == 2'd3) ? 2'd1 : ly_sel - 2'd1);
                        4'd1: ly_show[ly_sel] <= ~ly_show[ly_sel];
                        4'd2: ly_x[ly_sel*7 +: 7] <= inc ? ((sel_x >= 7'd79) ? 7'd79 : sel_x + 7'd1)
                                                         : ((sel_x == 7'd0) ? 7'd0 : sel_x - 7'd1);
                        4'd3: ly_y[ly_sel*6 +: 6] <= inc ? ((sel_y >= 6'd59) ? 6'd59 : sel_y + 6'd1)
                                                         : ((sel_y == 6'd0) ? 6'd0 : sel_y - 6'd1);
                        4'd4: ly_alpha[ly_sel*4 +: 4] <= inc ? ((sel_alpha >= 4'd10) ? 4'd10 : sel_alpha + 4'd1)
                                                             : ((sel_alpha == 4'd0) ? 4'd0 : sel_alpha - 4'd1);
                        4'd5: begin   // ORDER：和上 / 下一层交换
                            if (inc && sel_z != 2'd3) begin
                                for (j = 0; j < 4; j = j + 1)
                                    if (ly_z[j*2 +: 2] == sel_z + 2'd1) ly_z[j*2 +: 2] <= sel_z;
                                ly_z[ly_sel*2 +: 2] <= sel_z + 2'd1;
                            end else if (dec && sel_z != 2'd0) begin
                                for (j = 0; j < 4; j = j + 1)
                                    if (ly_z[j*2 +: 2] == sel_z - 2'd1) ly_z[j*2 +: 2] <= sel_z;
                                ly_z[ly_sel*2 +: 2] <= sel_z - 2'd1;
                            end
                        end
                        4'd6: ly_motion[ly_sel*2 +: 2] <= inc ? ((sel_mot == 2'd2) ? 2'd0 : sel_mot + 2'd1)
                                                              : ((sel_mot == 2'd0) ? 2'd2 : sel_mot - 2'd1);
                        default: if (inc) layer_defaults(ly_sel);
                    endcase
                    default: case (it_view)
                        4'd0: vw_sx <= inc ? ((vw_sx >= 5'd16) ? 5'd16 : vw_sx + 5'd1) : ((vw_sx <= 5'd1) ? 5'd1 : vw_sx - 5'd1);
                        4'd1: vw_sy <= inc ? ((vw_sy >= 5'd16) ? 5'd16 : vw_sy + 5'd1) : ((vw_sy <= 5'd1) ? 5'd1 : vw_sy - 5'd1);
                        4'd2: vw_mirror <= ~vw_mirror;
                        4'd3: vw_flip <= ~vw_flip;
                        4'd4: vw_panx <= inc ? ((vw_panx >= 6'sd20) ? 6'sd20 : vw_panx + 6'sd1)
                                             : ((vw_panx <= -6'sd20) ? -6'sd20 : vw_panx - 6'sd1);
                        4'd5: vw_pany <= inc ? ((vw_pany >= 6'sd15) ? 6'sd15 : vw_pany + 6'sd1)
                                             : ((vw_pany <= -6'sd15) ? -6'sd15 : vw_pany - 6'sd1);
                        // 可视化：关 / 频谱（R10 资源：波形 1 / 音量表 4 删掉；R8-2 删示波器 3）
                        4'd6: vw_viz <= (vw_viz == 3'd0) ? 3'd2 : 3'd0;
                        4'd7: vw_volume <= inc ? ((vw_volume >= 4'd10) ? 4'd10 : vw_volume + 4'd1)
                                               : ((vw_volume == 4'd0) ? 4'd0 : vw_volume - 4'd1);
                        default: if (inc) view_defaults;
                    endcase
                endcase
            end
        end
    end

    // ======================= 文字（中文，宏见 include/ui_text.vh）=======================
    function [7:0] dch;                 // 0~9 -> ASCII
        input [3:0] d;
        dch = 8'h30 + {4'd0, d};
    endfunction

    function [11:0] bcd3;               // 0~999 -> 三位 BCD（double dabble）
        input [9:0] n;
        integer k;
        reg [21:0] s;
        begin
            s = {12'd0, n};
            for (k = 0; k < 10; k = k + 1) begin
                if (s[13:10] >= 5) s[13:10] = s[13:10] + 4'd3;
                if (s[17:14] >= 5) s[17:14] = s[17:14] + 4'd3;
                if (s[21:18] >= 5) s[21:18] = s[21:18] + 4'd3;
                s = s << 1;
            end
            bcd3 = s[21:10];
        end
    endfunction

    function [39:0] idx_str;            // 右对齐 "  i/N" 或 " i/NN"
        input [3:0] i;                  // 0 起
        input [3:0] n;
        reg [3:0] i1;
        begin
            i1 = i + 4'd1;
            if (n < 10)
                idx_str = {"  ", dch(i1), "/", dch(n)};
            else
                idx_str = {(i1 >= 10) ? "1" : " ", dch((i1 >= 10) ? i1 - 4'd10 : i1), "/", "1", dch(n - 4'd10)};
        end
    endfunction

    reg [9:0] pub_cnt;
    // ---- 文字快照（每 1024 拍一次，不带复位：R7b-2 时序，复位扇出 2000 时 recovery -4.8ns）----
    // 第 1004 拍：选中图层的字段
    reg [6:0]   r_sel_x;
    reg [5:0]   r_sel_y;
    reg [3:0]   r_sel_alpha;
    reg [1:0]   r_sel_z;
    always @(posedge clk)
        if (pub_cnt == 10'd1004) begin
            r_sel_x <= sel_x;  r_sel_y <= sel_y;  r_sel_alpha <= sel_alpha;  r_sel_z <= sel_z;
        end
    // 第 1006 拍：状态快照；本页本项要显示的数字先选出来（只格式化这一个）
    localparam [2:0] NF_NONE = 3'd0, NF_N3SP = 3'd1, NF_PAN = 3'd2, NF_SCALE = 3'd3, NF_EFF = 3'd4, NF_DIG = 3'd5;
    reg [1:0]   q_page;
    reg [3:0]   q_it_trans, q_it_layer, q_it_view;
    reg [1:0]   q_sel, q_sel_mot, q_fx_mode;
    reg         q_fx_demo, q_show, q_mirror, q_flip, q_kb;
    reg [2:0]   q_viz;
    reg [5:0]   q_hint;
    reg [1:0]   q_sat;
    reg [2:0]   q_scl, q_itv;
    reg [3:0]   q_heff, q_fx;
    reg [7:0]   q_bri, q_con;
    reg         q_aut, q_mus;
    reg [39:0]  s_idx;
    reg [9:0]   n_val;
    reg [2:0]   n_fmt;
    reg         n_neg;
    reg [2:0]   q_cidx;                 // R8-1b：当前图（选字幕）
    reg [2:0]   q_cst;
    reg [3:0]   q_cmom;
    reg [7:0]   q_cdig, q_cgrp;
    reg [1:0]   q_cvoi, q_cnote;
    reg         q_cpr, q_c302, q_cbr, q_caseen, q_cswap;
    reg [15:0]  q_ctmr, q_ccmp, q_caed;
    reg [4:0]   q_ccyc;
    always @(posedge clk)
        if (pub_cnt == 10'd1006) begin
            q_page <= page;  q_cidx <= cidx;  q_it_trans <= it_trans;  q_it_layer <= it_layer;  q_it_view <= it_view;
            q_sel <= ly_sel;  q_sel_mot <= sel_mot;  q_fx_mode <= fx_mode;  q_fx <= fx_effect;
            q_fx_demo <= fx_demo;  q_show <= ly_show[ly_sel];  q_mirror <= vw_mirror;  q_flip <= vw_flip;
            q_kb <= vw_kenburns;  q_viz <= vw_viz;  q_hint <= hint;  q_heff <= hint_eff;
            q_bri <= dch(lv4(bri));  q_con <= dch(lv4(con));  q_aut <= aut;  q_mus <= mus;
            q_sat <= sat;  q_scl <= scl;  q_itv <= itv;
            s_idx <= (page == P_TRANS) ? idx_str(it_trans, N_TRANS) :
                     (page == P_LAYER) ? idx_str(it_layer, N_LAYER) : idx_str(it_view, N_VIEW);
            n_fmt <= NF_NONE;  n_val <= 10'd0;  n_neg <= 1'b0;
            case (page)
                P_TRANS: case (it_trans)
                    4'd0: begin n_fmt <= NF_EFF;  n_val <= {6'd0, fx_effect}; end
                    4'd1: begin n_fmt <= NF_DIG;  n_val <= {6'd0, fx_speed}; end
                    default: ;
                endcase
                P_LAYER: case (it_layer)
                    4'd2: begin n_fmt <= NF_N3SP; n_val <= {r_sel_x, 3'd0}; end                 // 单位 8 像素
                    4'd3: begin n_fmt <= NF_N3SP; n_val <= {1'b0, r_sel_y, 3'd0}; end
                    4'd4: begin n_fmt <= NF_N3SP; n_val <= {6'd0, r_sel_alpha} * 10'd10; end    // 0~100%
                    4'd5: begin n_fmt <= NF_DIG;  n_val <= {8'd0, r_sel_z} + 10'd1; end         // 层序 1~4
                    default: ;
                endcase
                P_VIEW: case (it_view)
                    4'd0: begin n_fmt <= NF_SCALE; n_val <= {5'd0, vw_sx}; end
                    4'd1: begin n_fmt <= NF_SCALE; n_val <= {5'd0, vw_sy}; end
                    4'd4: begin n_fmt <= NF_PAN;   n_val <= {vw_panx[5] ? -vw_panx : vw_panx, 4'd0}; n_neg <= vw_panx[5]; end   // 步数 × 16 像素
                    4'd5: begin n_fmt <= NF_PAN;   n_val <= {vw_pany[5] ? -vw_pany : vw_pany, 4'd0}; n_neg <= vw_pany[5]; end
                    4'd7: begin n_fmt <= NF_N3SP;  n_val <= {6'd0, vw_volume} * 10'd10; end
                    default: ;
                endcase
                default: ;
            endcase
            q_cst <= cst;  q_cpr <= cpr_on;  q_c302 <= c302;  q_cbr <= cbr;  q_caseen <= caseen;
            q_ctmr <= ctmr;  q_ccmp <= ccmp;  q_caed <= caed;  q_ccyc <= ccyc;
            q_cmom <= cmom;  q_cdig <= cdig;  q_cgrp <= cgrp;  q_cvoi <= cvoi;  q_cnote <= cnote;  q_cswap <= cswap;
        end
    // 第 1008 拍：变量字节 V1~V14（模板里的占位符 0x01~0x0E）
    //   平时：V1 亮度档 V2 对比度档 V3~V7 菜单项 "  i/N" V8~V11 本项数字
    //   急救：V1~V4 晕倒已过 mmss V5~V8 按压次数 V9~V10 第几组；交接页 V11~V14 AED 送到 mmss，其余时候 V11 V12 本组第几下、V13 一位数字
    reg [3:0] q_fc;
    reg [2:0] q_fa, q_ft;
    wire [7:0] q_fdig = {5'b00110, q_fa} + 8'd1;     // R9：故障条图号 "1"~"5"（V14，急救中不显示故障条）
    wire [7:0] q_ftot = {5'b00110, q_ft};            // R12：开机读图总张数 "1"~"5"（V13）
    reg  [119:0] vb;                        // vb[8n +: 8] = Vn（V0 不用）
    wire [11:0]  nb = bcd3(n_val);
    reg  [31:0]  vnum;                      // V8~V11
    always @* begin
        case (n_fmt)
            NF_N3SP:  vnum = {(nb[11:8] == 0) ? 8'h20 : dch(nb[11:8]),
                              (nb[11:8] == 0 && nb[7:4] == 0) ? 8'h20 : dch(nb[7:4]), dch(nb[3:0]), 8'h20};
            NF_PAN:   vnum = {n_neg ? "-" : "+", dch(nb[11:8]), dch(nb[7:4]), dch(nb[3:0])};
            NF_SCALE: vnum = {dch({1'b0, n_val[4:2]}),
                              (n_val[1:0] == 2'd0) ? "00" : (n_val[1:0] == 2'd1) ? "25" : (n_val[1:0] == 2'd2) ? "50" : "75", 8'h20};
            NF_EFF:   vnum = {(n_val[3:0] >= 4'd10) ? "1" : "0",
                              dch((n_val[3:0] >= 4'd10) ? n_val[3:0] - 4'd10 : n_val[3:0]), 16'h2020};
            NF_DIG:   vnum = {dch(n_val[3:0]), 24'h202020};
            default:  vnum = 32'h20202020;
        endcase
    end
    // R8-2 显示页（以及它的提示条）：V3~V6 色彩名、V7 V8 字幕颜色名、V9 V10 轮播间隔秒数
    reg  [31:0] sat_w;
    reg  [15:0] scl_w, itv_w;
    always @* begin
        case (q_sat)
            2'd0: sat_w = `T_SAT0;  2'd1: sat_w = `T_SAT1;  2'd2: sat_w = `T_SAT2;  default: sat_w = `T_SAT3;
        endcase
        case (q_scl)
            3'd0: scl_w = `T_SC0;  3'd1: scl_w = `T_SC1;  3'd2: scl_w = `T_SC2;  3'd3: scl_w = `T_SC3;
            3'd4: scl_w = `T_SC4;  3'd5: scl_w = `T_SC5;  3'd6: scl_w = `T_SC6;  default: scl_w = `T_SC7;
        endcase
        case (q_itv)
            3'd0: itv_w = " 1";  3'd1: itv_w = " 3";  3'd2: itv_w = " 5";  3'd3: itv_w = " 8";  3'd4: itv_w = "10";  default: itv_w = "15";
        endcase
    end
    always @(posedge clk)
        if (pub_cnt == 10'd1008) begin
            if (q_cpr)
                vb <= {(q_cst == 3'd4) ? {dch(q_caed[3:0]), dch(q_caed[7:4]), dch(q_caed[11:8]), dch(q_caed[15:12])} :   // V14~V11
                       {8'h20, q_cdig,                                                                       // V14 V13
                        dch((q_ccyc >= 5'd30) ? q_ccyc - 5'd30 : (q_ccyc >= 5'd20) ? q_ccyc - 5'd20 :
                            (q_ccyc >= 5'd10) ? q_ccyc - 5'd10 : q_ccyc[3:0]),                              // V12
                        (q_ccyc >= 5'd30) ? "3" : (q_ccyc >= 5'd20) ? "2" : (q_ccyc >= 5'd10) ? "1" : " "}, // V11
                       dch(q_cgrp[3:0]), dch(q_cgrp[7:4]),                                                  // V10 V9
                       dch(q_ccmp[3:0]), dch(q_ccmp[7:4]), dch(q_ccmp[11:8]), dch(q_ccmp[15:12]),          // V8~V5
                       dch(q_ctmr[3:0]), dch(q_ctmr[7:4]), dch(q_ctmr[11:8]), dch(q_ctmr[15:12]),          // V4~V1
                       8'h20};
            else if (q_page == P_PLAY)
                vb <= {q_fdig, q_ftot, 16'h2020, itv_w[7:0], itv_w[15:8], scl_w[7:0], scl_w[15:8],               // V14~V7
                       sat_w[7:0], sat_w[15:8], sat_w[23:16], sat_w[31:24],                                 // V6~V3
                       q_con, q_bri, 8'h20};                                                                 // V2 V1
            else
                vb <= {q_fdig, q_ftot, 8'h20, vnum[7:0], vnum[15:8], vnum[23:16], vnum[31:24],                   // V14~V8
                       s_idx[7:0], s_idx[15:8], s_idx[23:16], s_idx[31:24], s_idx[39:32],                   // V7~V3
                       q_con, q_bri, 8'h20};                                                                 // V2 V1
        end
    // R8-2b 状态栏第三行的变量字节（生成器第 7 行专用）：V1~V4 色彩名 V5 V6 字幕颜色 V7 V8 间隔秒数（急救中第三行是按键表、没有占位符）
    reg  [71:0]  vb7;
    always @(posedge clk)
        if (pub_cnt == 10'd1008)
            vb7 <= {itv_w[7:0], itv_w[15:8], scl_w[7:0], scl_w[15:8],
                    sat_w[7:0], sat_w[15:8], sat_w[23:16], sat_w[31:24], 8'h20};
    // R8-5c 状态栏第四行「原图1920x1080 缩小」：宽、"x"、高逐字符拼成左对齐 9 格（V1~V9，不足补空格）
    //   十进制用减 1000 / 100 / 10 逐位求，去掉前导 0；每格存 4 位码（0~9 数字、A = x、F = 空格），从高位移入 cv_sr。
    //   每 1024 拍在 pub_cnt = 0 时重新装载，约 60 拍转完停在 9；生成器写第 8 行（464~511 拍）时每用掉一个占位符
    //   就把 cv_sr 循环右移 4 位，按顺序取最低 4 位，9 个用完正好转回原样（省掉 9 选 1）
    reg  [3:0]  cv_st;                  // 0~3 宽的千 / 百 / 十 / 个位，4 "x"，5~8 高，9 补空格 / 停住，10 重新装载
    reg  [10:0] cv_v;
    reg  [3:0]  cv_d, cv_n;
    reg         cv_go;                  // 已经出过非 0 位
    reg  [35:0] cv_sr;
    wire        cv_unit = (cv_st == 4'd3) || (cv_st == 4'd8);
    wire        cv_dig  = (cv_st <= 4'd8) && (cv_st != 4'd4);
    wire [10:0] cv_k    = (cv_st == 4'd0 || cv_st == 4'd5) ? 11'd1000 : (cv_st == 4'd1 || cv_st == 4'd6) ? 11'd100 : 11'd10;
    // R9 时序：两拍走一步（约 120 拍转完，第 8 行在 464 拍以后才用）。cv_ph = 0 那拍只把比较 / 减数寄存，
    //   cv_ph = 1 那拍按寄存值走状态（原来 cv_st -> 减数选择 -> 比较 -> 状态 / 移位一拍 7 级，-0.5~-1.0ns）
    wire        cv_ph = pub_cnt[0];
    reg         cv_ge;
    reg  [10:0] cv_kr;
    always @(posedge clk) begin
        cv_ge <= (cv_v >= cv_k);
        cv_kr <= cv_k;
    end
    reg         cv_emit;
    reg  [3:0]  cv_ch;
    wire        cv_rot;                 // 生成器用掉第 8 行一个占位符（在下面生成器里给出）
    always @* begin
        cv_emit = 1'b0;  cv_ch = 4'hF;
        if (!cv_ph) begin
            // 不走
        end else if (cv_st == 4'd4) begin
            cv_emit = 1'b1;  cv_ch = 4'hA;
        end else if (cv_unit) begin
            cv_emit = 1'b1;  cv_ch = cv_v[3:0];
        end else if (cv_dig && !cv_ge) begin
            cv_emit = cv_go || (cv_d != 4'd0);  cv_ch = cv_d;
        end else if (cv_st == 4'd9) begin
            cv_emit = (cv_n != 4'd9);
        end
    end
    always @(posedge clk) begin
        if (cv_rot)
            cv_sr <= {cv_sr[3:0], cv_sr[35:4]};
        else if (cv_emit) begin
            cv_sr <= {cv_ch, cv_sr[35:4]};
            cv_n  <= cv_n + 4'd1;
        end
        if (pub_cnt == 10'd0) begin
            cv_st <= 4'd10;
        end else if (!cv_ph) begin
            // 不走
        end else if (cv_st == 4'd10) begin
            cv_v <= cur_wh_in[21:11];  cv_d <= 4'd0;  cv_go <= 1'b0;  cv_n <= 4'd0;  cv_st <= 4'd0;
        end else if (cv_st == 4'd9) begin
            // 9 格齐了就停在这里
        end else if (cv_st == 4'd4) begin
            cv_v <= cur_wh_in[10:0];  cv_st <= 4'd5;
        end else if (cv_unit) begin
            cv_go <= 1'b0;  cv_st <= cv_st + 4'd1;
        end else if (cv_ge) begin
            cv_v <= cv_v - cv_kr;  cv_d <= cv_d + 4'd1;
        end else begin
            if (cv_d != 4'd0) cv_go <= 1'b1;
            cv_d <= 4'd0;  cv_st <= cv_st + 4'd1;
        end
    end
    wire [7:0]  cv_q = (cv_sr[3:0] == 4'hA) ? "x" : (cv_sr[3:0] > 4'd9) ? 8'h20 : {4'h3, cv_sr[3:0]};
    // 模式 缩小 / 原尺寸 / 放大（宽 = 0 表示这张没有记录，第四行留空）
    reg         r_dn, r_eq, r_none;
    always @(posedge clk)
        if (pub_cnt == 10'd1008) begin
            r_dn   <= (cur_wh_in[21:11] > 11'd640) || (cur_wh_in[10:0] > 11'd480);
            r_eq   <= (cur_wh_in[21:11] == 11'd640) && (cur_wh_in[10:0] == 11'd480);
            r_none <= (cur_wh_in[21:11] == 11'd0);
        end
    // 第 1010 拍：每行用哪段模板（ROM 起始地址），效果名词的地址
    reg  [12:0] lb0, lb1, lb2, lb3, lb4, lb5, lb6, lb7, lb8, wb3, wb4;   // R9：文字 ROM 5120 字节，地址 13 位
    function [12:0] eff_word;
        input [3:0] e;
        case (e)
            4'd0:  eff_word = `XW_E00;  4'd1:  eff_word = `XW_E01;  4'd2:  eff_word = `XW_E02;
            4'd3:  eff_word = `XW_E03;  4'd4:  eff_word = `XW_E04;  4'd5:  eff_word = `XW_E05;
            4'd6:  eff_word = `XW_E06;  4'd7:  eff_word = `XW_E07;  4'd8:  eff_word = `XW_E08;
            4'd9:  eff_word = `XW_E09;  4'd10: eff_word = `XW_E10;  4'd11: eff_word = `XW_E11;
            4'd12: eff_word = `XW_E12;  4'd13: eff_word = `XW_E13;  4'd14: eff_word = `XW_E14;  default: eff_word = `XW_E15;
        endcase
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_fc <= 4'd0;  q_fa <= 3'd0;  q_ft <= 3'd0;  fault_show <= 1'b0;  note_show <= 1'b0;
        end else begin
            q_fc <= fault_code;  q_fa <= fault_arg;  q_ft <= fault_tot;  fault_show <= (q_fc != 4'd0) && (q_fc != 4'd14);
            note_show <= (q_fc == 4'd14) || ((q_fc == 4'd0) && cpr_on && (cnote != 2'd0));   // R12：14 = 开机读图（黄框）
        end
    end
    always @(posedge clk)
        if (pub_cnt == 10'd1010) begin
            wb3 <= eff_word(q_fx);
            case (q_cidx)                       // R8-1b：每张轮播图一条字幕（R11：4 张）
                3'd0: lb5 <= `X_SUB1;  3'd1: lb5 <= `X_SUB2;  3'd2: lb5 <= `X_SUB3;
                default: lb5 <= `X_SUB4;
            endcase
            wb4 <= eff_word(q_heff);
            lb7 <= !q_cpr ? `X_S3_N : (q_cst == 3'd1) ? `X_S3_CK1 : (q_cst == 3'd2) ? `X_S3_CK2 :   // R9：急救中第三行 = 本部分按键
                   (q_cst == 3'd3) ? `X_S3_CK3 : `X_S3_CKE;
            lb8 <= (q_cpr || r_none) ? `X_H_NONE : r_dn ? `X_S4_DN : r_eq ? `X_S4_EQ : `X_S4_UP;   // R8-5c 第四行（急救中状态栏只 3 行）
            // 急救文字（每行 24 格）
            //   左上（状态栏框）进行中：「晕倒已过 03:25 单纯按压」/「按压 0120 次  12/30」（30:2 才显示轮次）
            //                   交接页：「急救结束」/「晕倒已过 12:48」
            //   右上（菜单框）  ①「第 1 步  呼救」/「误触请长按急救键取消」  ②「第 2 步  胸外按压」/「AED 送到后请按 K3」
            //                   ③「第 3 步  贴电极片」等 /「AED 第 04:10 送到」  交接页「按压节拍 1050 次」/ AED 那一行或「AED 未送到」
            //   R9：左上 3 行「晕倒已过 03:25  语音开」/「30:2 第03组 按压0087次」/ 本部分按键；右上 = 这一时刻的两行要点；
            //   底部（提示条框，2 倍字）= 口令（带图上编号，和语音同一句）
            if (q_cpr) begin
                if (q_cst == 3'd4) begin
                    lb0 <= `X_S1_CEND;   lb1 <= `X_S2_CEND;   lb2 <= `X_M1_CBEATS;
                    lb3 <= q_caseen ? `X_M2_CAED : `X_M2_CNOAED;
                end else begin
                    lb0 <= q_cvoi[1] ? `X_S1_CVN : q_cvoi[0] ? `X_S1_CV0 : `X_S1_CV1;
                    lb1 <= q_c302 ? `X_S2_C302 : `X_S2_CPURE;
                    if (q_cswap)                         // R11：换人提示期间右上 = 换人要领
                        begin lb2 <= `X_M1_CTSW;  lb3 <= `X_M2_CTSW; end
                    else case (q_cmom)
                        CM_1Z:   begin lb2 <= `X_M1_CT1Z;  lb3 <= `X_M2_CT1Z; end
                        CM_1A:   begin lb2 <= `X_M1_CT1A;  lb3 <= `X_M2_CT1A; end
                        CM_1B:   begin lb2 <= `X_M1_CT1B;  lb3 <= `X_M2_CT1B; end
                        CM_1C:   begin lb2 <= `X_M1_CT1C;  lb3 <= `X_M2_CT1C; end
                        CM_1D:   begin lb2 <= `X_M1_CT1D;  lb3 <= `X_M2_CT1D; end
                        CM_2I, CM_2S:
                                 begin lb2 <= `X_M1_CT2I;  lb3 <= `X_M2_CT2I; end
                        CM_2R:   begin lb2 <= `X_M1_CT2R;  lb3 <= `X_M2_CT2R; end
                        CM_2C:   begin lb2 <= `X_M1_CT2C;  lb3 <= `X_M2_CT2C; end
                        CM_BR, CM_BE:
                                 begin lb2 <= `X_M1_CTBR;  lb3 <= `X_M2_CTBR; end
                        CM_3A:   begin lb2 <= `X_M1_CT3A;  lb3 <= `X_M2_CT3A; end
                        default: begin lb2 <= `X_M1_CT3B;  lb3 <= `X_M2_CT3B; end
                    endcase
                end
                case (q_cmom)
                    CM_1Z:   lb4 <= `X_H_C_1Z;
                    CM_1A:   lb4 <= `X_H_C_1A;
                    CM_1B:   lb4 <= `X_H_C_1B;
                    CM_1C:   lb4 <= `X_H_C_1C;
                    CM_1D:   lb4 <= `X_H_C_1D;
                    CM_2I:   lb4 <= `X_H_C_2I;
                    CM_2S:   lb4 <= `X_H_C_2S;
                    CM_2R:   lb4 <= `X_H_C_2R;
                    CM_2C:   lb4 <= `X_H_C_2C;
                    CM_BR:   lb4 <= `X_H_C_BR;
                    CM_BE:   lb4 <= `X_H_C_BE;
                    CM_3A:   lb4 <= `X_H_C_3A;
                    CM_3B:   lb4 <= `X_H_C_3B;
                    default: lb4 <= `X_H_C_END;
                endcase
            end else begin
                case ({q_aut, q_mus})
                    2'b00: lb0 <= `X_S1_A0M0;  2'b01: lb0 <= `X_S1_A0M1;
                    2'b10: lb0 <= `X_S1_A1M0;  default: lb0 <= `X_S1_A1M1;
                endcase
                lb1 <= `X_S2_N;
                case (q_page)
                    P_TRANS: lb2 <= `X_M1_TRANS;
                    P_LAYER: case (q_sel)
                        2'd0: lb2 <= `X_M1_LAYER0;  2'd1: lb2 <= `X_M1_LAYER1;
                        2'd2: lb2 <= `X_M1_LAYER2;  default: lb2 <= `X_M1_LAYER3;
                    endcase
                    P_VIEW:  lb2 <= `X_M1_VIEW;
                    default: lb2 <= `X_M1_DISP;
                endcase
                case (q_page)
                    P_TRANS: case (q_it_trans)
                        4'd0: lb3 <= `X_M2_EFFECT;
                        4'd1: lb3 <= `X_M2_SPEED;
                        default: lb3 <= (q_fx_mode == 2'd0) ? `X_M2_MODE0 : (q_fx_mode == 2'd1) ? `X_M2_MODE1 : `X_M2_MODE2;
                    endcase
                    P_LAYER: case (q_it_layer)
                        4'd0: case (q_sel)
                            2'd0: lb3 <= `X_M2_SEL0;  2'd1: lb3 <= `X_M2_SEL1;
                            2'd2: lb3 <= `X_M2_SEL2;  default: lb3 <= `X_M2_SEL3;
                        endcase
                        4'd1: lb3 <= q_show ? `X_M2_SHOW1 : `X_M2_SHOW0;
                        4'd2: lb3 <= `X_M2_X;
                        4'd3: lb3 <= `X_M2_Y;
                        4'd4: lb3 <= `X_M2_ALPHA;
                        4'd5: lb3 <= `X_M2_ORDER;
                        4'd6: lb3 <= (q_sel_mot == 2'd0) ? `X_M2_MOT0 : (q_sel_mot == 2'd1) ? `X_M2_MOT1 : `X_M2_MOT2;
                        default: lb3 <= `X_M2_LRESET;
                    endcase
                    P_VIEW: case (q_it_view)
                        4'd0: lb3 <= `X_M2_SX;
                        4'd1: lb3 <= `X_M2_SY;
                        4'd2: lb3 <= q_mirror ? `X_M2_MIR1 : `X_M2_MIR0;
                        4'd3: lb3 <= q_flip ? `X_M2_FLIP1 : `X_M2_FLIP0;
                        4'd4: lb3 <= `X_M2_PANX;
                        4'd5: lb3 <= `X_M2_PANY;
                        4'd6: lb3 <= (q_viz == 3'd0) ? `X_M2_VIZ0 : `X_M2_VIZ2;
                        4'd7: lb3 <= `X_M2_VOL;
                        default: lb3 <= `X_M2_VRESET;
                    endcase
                    default: lb3 <= `X_M2_DISP;
                endcase
                case (q_hint)
                    H_AUTO_ON:  lb4 <= `X_H_AUTO_ON;   H_AUTO_OFF: lb4 <= `X_H_AUTO_OFF;
                    H_MUS_ON:   lb4 <= `X_H_MUS_ON;    H_MUS_OFF:  lb4 <= `X_H_MUS_OFF;
                    H_SET_ON:   lb4 <= `X_H_SET_ON;    H_SET_OFF:  lb4 <= `X_H_SET_OFF;
                    H_SW1:      lb4 <= `X_H_SW1;
                    H_BRI1, H_BRI2, H_BRI3, H_BRI4: lb4 <= `X_H_BRI;     // R9：档位数字 = V1 / V2（就是当前档）
                    H_CON1, H_CON2, H_CON3, H_CON4: lb4 <= `X_H_CON;
                    H_THUMB:    lb4 <= `X_H_THUMB;     H_FULL:     lb4 <= `X_H_FULL;
                    H_PLAY:     lb4 <= `X_H_PLAY;      H_TRANS:    lb4 <= `X_H_TRANS;
                    H_LAYER:    lb4 <= `X_H_LAYER;     H_VIEW:     lb4 <= `X_H_VIEW;
                    H_NEXT:     lb4 <= `X_H_NEXT;      H_PREV:     lb4 <= `X_H_PREV;
                    H_EFF:      lb4 <= `X_H_EFF;       H_TFOK:     lb4 <= `X_H_TFOK;
                    H_SUBOK:    lb4 <= `X_H_SUBOK;     H_SUBRST:   lb4 <= `X_H_SUBRST;
                    H_SAT:      lb4 <= `X_H_SAT;       H_SCOL:     lb4 <= `X_H_SCOL;
                    H_INT:      lb4 <= `X_H_INT;
                    H_SUB0:     lb4 <= `X_H_SUB0;      H_SUB1:     lb4 <= `X_H_SUB1;
                    H_FRST:     lb4 <= `X_H_FRST;      H_WFAIL:    lb4 <= `X_H_WFAIL;
                    H_LAST:     lb4 <= `X_H_LAST;
                    H_STAT0:    lb4 <= `X_H_STAT0;     H_STAT1:    lb4 <= `X_H_STAT1;
                    H_VIZ0:     lb4 <= `X_H_VIZ0;      H_VIZ1:     lb4 <= `X_H_VIZ1;
                    default:    lb4 <= `X_H_NONE;
                endcase
            end
            case (q_fc)
                4'd1:  lb6 <= `X_F_NOCARD;
                4'd2:  lb6 <= `X_F_FORMAT;
                4'd3:  lb6 <= `X_F_NOPIC;
                4'd4:  lb6 <= `X_F_LOST;
                4'd5:  lb6 <= `X_F_BADIMG;
                4'd8:  lb6 <= `X_F_MISS;            // R9：图号 = V14（q_fdig）
                4'd9:  lb6 <= `X_F_BAD;
                4'd10: lb6 <= `X_F_NOMUSIC;
                4'd11: lb6 <= `X_F_CRC;
                4'd12: lb6 <= `X_F_MISS6;
                4'd13: lb6 <= `X_F_BAD6;
                4'd14: lb6 <= `X_F_LOAD;            // R12：正在读取图片 n/m（V14 / V13）
                default: lb6 <= !q_cpr ? `X_F_NONE : (q_cnote == 2'd1) ? `X_F_NK3 : (q_cnote == 2'd2) ? `X_F_NSW : `X_F_NONE;   // R11 急救正中黄框
            endcase
        end

    // ---- 文字生成器：按 gc = pub_cnt + 6 提前读 ROM，第 k 个字节在 pub_cnt = 2k 时已在 gbyte 里 ----
    //   行 0 状态栏 1 / 1 状态栏 2 / 2 菜单 1 / 3 菜单 2 / 4 提示条 / 5 字幕条（64 格）/ 6 故障条 / 7 状态栏 3（R8-2b），共 232 字节
    //   ROM 单口分时：奇数拍读模板字节，偶数拍读词表字节（只有菜单 2 和提示条有词）
    //   第 k 字节：2k 算模板地址 -> 2k+1 读模板 -> 2k+3 算词地址 -> 2k+4 读词 -> 2k+5 替换占位符 -> 2k+6 起可用
    wire [9:0]  gc = pub_cnt + 10'd6;
    reg  [3:0]  gl, gl_a, gl_b, gl_c;     // R8-5c：9 行（0~8）
    reg  [5:0]  gp;
    reg  [12:0] ta, wa;
    reg  [7:0]  tb0, tb1, gbyte;
    wire [7:0]  rq;
    text_rom u_text_rom (.clk(clk), .addr(gc[0] ? ta : wa), .q(rq));
    assign cv_rot = gc[0] && (gl_c == 4'd8) && (tb1[7:4] == 4'd0);   // 和下面 gbyte 取 cv_q 同一拍
    reg  [12:0] lbase;
    always @* begin
        case (gl)
            4'd0: lbase = lb0;  4'd1: lbase = lb1;  4'd2: lbase = lb2;  4'd3: lbase = lb3;
            4'd4: lbase = lb4;  4'd5: lbase = lb5;  4'd6: lbase = lb6;  4'd7: lbase = lb7;
            default: lbase = lb8;
        endcase
    end
    always @(posedge clk) begin
        if (gc == 10'd1023) begin
            gl <= 4'd0;  gp <= 6'd0;
        end else if (gc[0]) begin
            if (gp == ((gl == 4'd5) ? 6'd63 : 6'd23)) begin
                gl <= gl + 4'd1;  gp <= 6'd0;
            end else
                gp <= gp + 6'd1;
        end
        if (!gc[0]) begin
            ta   <= lbase + {7'd0, gp};
            gl_a <= gl;
            tb0  <= rq;                                    // 模板字节（上一拍按 ta 读出）
            tb1  <= tb0;
        end else begin
            gl_b  <= gl_a;
            gl_c  <= gl_b;                                 // tb1 那个字节所在的行
            wa    <= ((gl_b == 4'd4) ? wb4 : wb3) + {9'd0, tb0[3:0]};
            gbyte <= (tb1[7:5] != 3'd0) ? tb1 : tb1[4] ? rq :
                     (gl_c == 4'd7) ? vb7[{tb1[3:0], 3'b000} +: 8] :
                     (gl_c == 4'd8) ? cv_q : vb[{tb1[3:0], 3'b000} +: 8];
        end
    end

    // ---- 写文字 RAM：每 1024 拍的第 0~463 拍，每字节 2 拍（0~119 界面文字、120~183 字幕条 -> RAM 128~191、184~207 故障条 -> RAM 224~247、
    //      208~231 状态栏 3 -> RAM 192~215）----
    // 汉字两字节 {8'h80|k, 标记 7F/7E}：遇到标记时写右半 {1, 页, 码}，下一个偶数拍再把左半补写成 {0, 页, 码}
    wire [8:0]  wk  = pub_cnt[9:1];                 // 第几个字节
    reg  [7:0]  wb, wprev, lcode;
    reg  [7:0]  lad;
    reg  [1:0]  lpg;
    reg         lpend;
    //      R8-5c：232~255 状态栏 4 -> RAM 120~127 / 216~223 / 248~255（三段 8 格空位，cn_text_overlay 读时同样拼回）
    wire        in_w = (pub_cnt < 10'd512);
    wire [7:0]  wk_addr = (wk >= 9'd248) ? wk[7:0] : (wk >= 9'd240) ? {5'b11011, wk[2:0]} : (wk >= 9'd232) ? {5'b01111, wk[2:0]} :
                          (wk >= 9'd208) ? wk[7:0] - 8'd16 : (wk >= 9'd184) ? wk[7:0] + 8'd40 :
                          (wk >= 9'd120) ? wk[7:0] + 8'd8 : wk[7:0];
    wire        is_mark = (wb == 8'h7f) || (wb == 8'h7e) || (wb == 8'h7d);   // 汉字第 0 / 1 / 2 页标记
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pub_cnt <= 10'd0;
            wb <= 8'h20;  wprev <= 8'h20;  lcode <= 8'h20;  lad <= 8'd0;  lpg <= 2'd0;  lpend <= 1'b0;
            txt_we <= 1'b0;  txt_addr <= 8'd0;  txt_data <= 11'h020;
        end else begin
            pub_cnt <= pub_cnt + 10'd1;
            txt_we <= 1'b0;
            if (in_w && !pub_cnt[0]) begin
                wb <= gbyte;
                if (lpend) begin                    // 补写上一个汉字的左半（带页号）
                    txt_we <= 1'b1;  txt_addr <= lad;  txt_data <= {1'b0, lpg, lcode};
                    lpend <= 1'b0;
                end
            end else if (in_w) begin
                txt_we   <= 1'b1;
                txt_addr <= wk_addr;
                if (is_mark) begin
                    txt_data <= {1'b1, ~wb[1:0], wprev};          // 7F / 7E / 7D -> 页 0 / 1 / 2
                    lpend <= 1'b1;  lad <= wk_addr - 8'd1;  lcode <= wprev;  lpg <= ~wb[1:0];
                end else begin
                    txt_data <= {3'b000, wb};
                    wprev <= wb;
                end
            end
        end
    end
endmodule
