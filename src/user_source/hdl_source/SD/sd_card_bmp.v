
// 第8课起：本模块只负责“TF 卡 -> 像素流”。上电扫描 FAT32 后，把找到的图依次加载进 SDRAM 的
// 四个 bank（第 n 张 -> bank n），全部加载完才打开显示（player_enable）。
// 双缓冲管理、按键切图、自动轮播都移到了顶层的 media_player_control（文档 5.4 修改点7）。
// R7b-1：轮播图按顺序压紧进 bank0~N-1；之后再把急救专用图加载进固定的 bank，不参与压紧、不计入 img_found_count。
// R8-1a：6 张图 = PIC1~5 轮播（压紧进 bank0~4）+ PIC6 急救专用（固定 bank5）。急救时由 media_frame_reader 的覆盖读 bank5。
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,        // 第6课起不再使用（物理扇区扫描已换成 FAT32），保留只为顶层不用改
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,   // 同上
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,         // 同上
    parameter integer LONG_PRESS_MS     = 1000,   // R8-0a 起不再使用（按键全部移到 ui_key_router），保留只为例化不用改
    parameter integer AUTO_PLAY_MS      = 3000,   // 第8课起不再使用（轮播周期在 media_player_control），保留只为顶层不用改
    parameter integer LOAD_TIMEOUT_MS   = 8000,   // 单张图加载超时，超时放弃本次加载（R8-5a：1080p 一张约 2.5 秒，1000 -> 8000）
    parameter integer OUT_W             = 640,    // R8-5a：帧缓存一张图的尺寸（原图缩放到这个尺寸）
    parameter integer OUT_H             = 480,
    parameter integer MAX_RETRIES       = 1,      // 第4课 2.2：加载失败重试次数
    parameter integer LOST_MS           = 300,    // R4：显示中一次扇区读超过这么久没完成 = TF 卡丢失
    parameter integer PROBE_MS          = 1000,   // R4：显示中 SD 空闲这么久就读一次扇区 0 探测卡还在不在
    parameter integer RETRY_MS          = 2000,   // R4：上电失败（没卡 / 格式错 / 没图）后隔这么久重新初始化
    parameter integer EXT_MS            = 0       // R12b：1 = 用 ms_tick_in（顶层共用的 1ms 节拍）
)(
    input                       clk,
    input                       rst,
    input                       ms_tick_in,       // R12b：EXT_MS = 1 时用
    input                       sdram_init_done,  // 第5课：SDRAM 初始化完成（已同步到本时钟域）
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,    // 第8课：= player_enable，四张图都加载完（或已放弃）才打开显示
    output      [3:0]           state_code,
    output                      loading,          // 正在加载（上电依次加载 4 张）
    output reg [11:0]           last_load_time,   // 诊断：上一次加载耗时，BCD 三位，单位 10ms（最大 9.99s）
    output reg                  last_load_err,    // 诊断：上一次加载失败被放弃
    output reg [3:0]            abort_code,       // 诊断：失败那一刻卡在哪（见下方 abort 代码表）
    output reg [1:0]            abort_sd_stage,   // 诊断：失败那一刻 SD 命令层阶段（0 空闲 1 命令 2 等令牌 3 读数据）
    output     [7:0]            crc_err_cnt,      // 诊断：扇区 CRC16 错误累计次数
    output     [7:0]            rd_retry_cnt,     // 诊断：读扇区重试累计次数
    output     [7:0]            crc_fail_cnt,     // 诊断：扇区重放缓冲重读也救不回来、带错交出的扇区数
    output     [7:0]            fs_error,         // 第6课诊断：FAT32 卷扫描错误码（0x10 读扇区 0x20 引导签名 0x21 BPB 不支持 0x22 缺图）
    output reg [2:0]            img_found_count,  // 第8课：找到几张图（= 用到几个 bank）
    // R4 故障提示 / 自动恢复
    output                      sd_ready,         // SD 初始化完成
    output                      boot_done,        // 上电加载流程结束（IG_DONE）
    output reg  [5:0]           found_mask,       // 扫描到的 PIC1~6（按文件编号，bit5 = PIC6）
    output reg  [5:0]           giveup_mask,      // 加载失败被放弃的图（按 bank，bit5 = bank5 = PIC6）
    output reg                  emg_ok,           // R8-1a：PIC6（急救专用图）已加载进 bank5
    output reg                  tf_lost,          // 显示中 TF 卡读不动了（拔卡），恢复后清零
    output reg                  tf_recovered,     // 单拍：tf_lost 恢复

    // 第8课：给 media_frame_loader 的像素流（文档 5.4 修改点7）
    output reg                  loader_load_start,   // 单拍：开始加载一张图
    output     [2:0]            loader_image_index,  // 写哪个 bank（5 = PIC6）
    output                      loader_pixel_valid,
    output     [23:0]           loader_pixel_rgb,
    output reg                  loader_frame_commit, // 单拍：这张图的像素已全部送出
    output     [7:0]            loader_decode_error, // 非 0：本次加载失败（bmp_read 报错或加载超时），loader 立即结束
    input                       loader_pixel_ready,  // R8-5a：loader FIFO 还有余量（缩放输出侧反压）
    output                      loader_top_down,     // R8-5b：当前这张是负高度 BMP（自上而下），loader 不翻转
    input      [2:0]            cur_pic,             // R8-5c：当前显示第几个 bank（已同步到本时钟域）
    output reg [21:0]           cur_wh,              // R8-5c：当前图原始 {宽, 高}（各 11 位），给状态栏第四行
    input                       loader_load_done,
    input      [7:0]            loader_memory_error,
    output reg                  cdc_clear,           // 加载失败后清空 SDRAM 写 CDC（丢掉不完整的半个 burst）
    input                       cdc_idle,            // SDRAM 写 CDC 已排空（已同步到本时钟域）

    // 第11课：MUSIC.WAV 的位置，以及图片加载完之后交给 wav_stream_player 的扇区读口
    output reg                  music_found,
    output reg  [31:0]          music_start_lba,     // PCM 数据第一个扇区（文件第 2 个扇区，前 512 字节是 WAV 头）
    output reg  [31:0]          music_sectors,       // PCM 数据扇区数
    // R8-4a：掉电保存。扫描完、加载图片前读一次 SAVE.BIN 第一个扇区，魔数 / 版本 / 校验都对就发 save_ld
    output reg                  save_ld,             // 单拍：存档有效，save_dat 可用
    output reg [199:0]          save_dat,            // 存档前 25 字节（字节 n = [8n+7:8n]），save_ld 之后不变
    // R8-4b：写回。只覆盖 SAVE.BIN 第一个扇区（地址 = 开机读的同一个 save_lba），只在显示中（IG_DONE）写
    input                       save_req,            // 单拍：写一次（写的时候又来一次 -> 写完再写一次）
    input      [255:0]          save_img,            // 前 32 字节，其余 480 字节写 0
    output reg                  save_fail,           // 单拍：写卡超时（本次开机不再写，按拔卡处理 SD 层）
    // R9：急救语音 GUIDE.WAV（数据起点 = 文件第 2 个扇区）；急救位置条点阵存 SAVE.BIN 第 2、3 扇区
    output reg                  guide_found,
    output reg  [31:0]          guide_lba,
    input                       u_loc_we,            // 电脑串口 CMD 03 写位置点阵（uart_subtitle）
    input       [9:0]           u_loc_addr,
    input       [7:0]           u_loc_data,
    input                       u_loc_ev,            //   单拍：收完且校验对 -> 写回 TF 卡
    output reg                  loc_we,              // 合并后的位置点阵写口（给 emg_overlay）：开机读卡 / 串口
    output reg  [9:0]           loc_addr,
    output reg  [7:0]           loc_data,
    output      [9:0]           loc_ra,              // 写回时读位置点阵（emg_overlay 的 sd_card_clk 读口，1 拍延迟）
    input       [7:0]           loc_q,
    output                      wav_sd_enable,       // 1：SD 读卡口归 WAV 播放器
    input                       wav_sector_req,
    input       [31:0]          wav_sector_lba,
    output                      wav_sector_busy,
    output                      wav_sector_valid,
    output      [7:0]           wav_sector_byte,
    output      [8:0]           wav_sector_byte_index,
    output                      wav_sector_done,
    output      [7:0]           wav_sector_error,

    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

// R8-5b 资源：下面这些超时 / 计时（看门狗、加载超时、拔卡检测、空闲探测、上电重试、加载耗时）原来各数时钟（24~30 位），
// 改成数共用的 1ms 节拍 ms_tick（误差 < 1ms），省约 250 LUT；R12b 资源：EXT_MS = 1 时用顶层共用的 1ms 节拍 ms_tick_in（本地再寄存一拍，跨模块长线留一整拍），不再自己分频
localparam integer MS_CYCLES = CLK_FREQ_HZ / 1000;
reg [16:0] ms_div;
reg        ms_tick;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        ms_div  <= 17'd0;
        ms_tick <= 1'b0;
    end else if (EXT_MS) begin
        ms_tick <= ms_tick_in;
    end else begin
        ms_tick <= (ms_div == MS_CYCLES - 1);
        ms_div  <= (ms_div == MS_CYCLES - 1) ? 17'd0 : ms_div + 17'd1;
    end
end


wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;

// SD 初始化看门狗：上电 / 复位后 1.5s 还没初始化完成，就单独把 SD 读卡层复位一次重新初始化
// （重新发 80 个空时钟 + CMD0）。官方初始化在 CMD8/CMD55 出错时只重发本条命令、不回 CMD0：
// 复位瞬间卡正在送扇区数据时，残留数据字节可能被当成 CMD0 的应答，卡其实没回到 idle，
// 之后 CMD8 永远对不上应答 -> 数码管一直显示 0。以前要按 K1 才能恢复，现在自动恢复。
localparam integer SD_INIT_WD_MS = 1500;
reg              sd_reinit_req;        // R4：单拍，请求复位 SD 读卡层重新初始化
reg  [10:0]      sd_init_wd_cnt;       // 单位 1ms
reg  [9:0]       sd_wd_rst_cnt;
wire             sd_wd_rst = (sd_wd_rst_cnt != 10'd0);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_init_wd_cnt <= 11'd0;
        sd_wd_rst_cnt  <= 10'd0;
    end else if (sd_wd_rst) begin
        sd_init_wd_cnt <= 11'd0;
        sd_wd_rst_cnt  <= sd_wd_rst_cnt - 10'd1;     // 复位保持 1023 拍（约 10us）
    end else if (sd_reinit_req) begin
        sd_init_wd_cnt <= 11'd0;                     // R4：拔卡 / 上电失败后主动重新初始化
        sd_wd_rst_cnt  <= 10'd1023;
    end else if (sd_init_done) begin
        sd_init_wd_cnt <= 11'd0;
    end else if (sd_init_wd_cnt >= SD_INIT_WD_MS) begin
        sd_init_wd_cnt <= 11'd0;
        sd_wd_rst_cnt  <= 10'd1023;
    end else if (ms_tick) begin
        sd_init_wd_cnt <= sd_init_wd_cnt + 11'd1;
    end
end
wire             bmp_ready;
wire [10:0]      src_w, src_h;         // R8-5c：bmp_read 解析出的原图宽高
wire             bmp_src_hold;         // R8-5a：bmp_read 要求暂停文件字节流
reg              scan_done;            // 卷扫描已结束（电平；扫描器的 scan_done 是单拍脉冲）
wire             fs_scan_done;         // 扫描器完成脉冲
wire             fs_scan_busy;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_cluster;         // 第6课：起始簇号 + 文件大小取代起始扇区
reg [31:0]       load_file_size;
reg              scan_kicked;
reg [2:0]        load_idx;             // 当前正在加载第几张（= 写哪个 bank，5 = PIC6）
// 优化 A5：簇号 / 大小不再复制一份（扫描器里已保存，扫描后不变），按压紧后的序号从扫描器输出里选
reg              load_busy;
reg [13:0]       load_timeout_cnt;     // 单位 1ms（R8-5a：8 秒）

reg              load_abort;
reg              loaded_any;           // R4：至少有一张图加载成功
reg              hot;                  // R4：热恢复进行中（显示不关）
reg  [11:0] busy_cnt, idle_cnt, retry_cnt;   // 单位 1ms
reg         probe_on, probe_req;
reg         wr_tmo;                    // R8-4b：写卡超时单拍（按拔卡处理）
wire        hot_start = (ig_state == IG_DONE) && display_valid && ((busy_cnt >= LOST_MS) || wr_tmo);

// 第4课 2.2 错误恢复：重试 1 次 -> 失败跳过（这张图的 bank 不标记完成，播放时自动跳过）
wire             load_error;           // bmp_read 加载失败脉冲
wire [2:0]       bmp_error;            // bmp_read 错误码：1 头校验 2 SD 超时 3 像素截断 4 FAT 链错误
reg  [1:0]       retry_count;
reg              load_giveup;          // 重试用完、放弃这张图（单拍，给数码管诊断）
reg              load_commit;          // 这张图加载成功（单拍，给数码管诊断）

// 第8课：上电加载流程
localparam [2:0] IG_WAIT  = 3'd0;      // 等扫描结束
localparam [2:0] IG_START = 3'd1;      // 启动一张图的加载
localparam [2:0] IG_RUN   = 3'd2;      // 等 loader 报告这张图结束
localparam [2:0] IG_GAP   = 3'd3;      // 两次加载之间的间隔（失败时在这里清 CDC）
localparam [2:0] IG_DRAIN = 3'd4;      // 全部加载完，等 SDRAM 写 CDC 排空
localparam [2:0] IG_DONE  = 3'd5;      // 打开显示
localparam [2:0] IG_HOT   = 3'd6;      // R4：显示中拔卡后重新初始化 + 重新扫描（只为找回 MUSIC.WAV，图片还在 SDRAM 里不重读）
localparam [2:0] IG_SAVE  = 3'd7;      // R8-4a：扫描完先读 SAVE.BIN（没有就直接过），再加载图片
reg              ig_after;             // IG_SAVE 之后：1 = 加载图片，0 = 一张都没找到，直接 IG_DONE
reg              sv_start;             // 单拍：IG_SAVE 发起存档读
wire             sv_end;               // 单拍：存档读结束（成功 / 校验错 / 超时都算）
reg              sv_on, sv_req, sv_chk, sv_end_r, sv_wait;
reg              sv_rd_ok;             // R8-4b：开机读过 SAVE.BIN 扇区（拔卡热恢复不清，冷启动重读）
reg              wr_own;               // R8-4b：写卡占用 SD 口（WAV / 探测都挡住）
wire             sv_busy = sv_on | sv_chk;
reg              save_lba_ok;
reg  [2:0]       ig_state;
reg  [9:0]       ig_cnt;
reg  [2:0]       ig_next_idx;          // IG_GAP 之后加载哪一张
reg  [2:0]       seq_nx_idx;           // R7b-1：当前这张之后按顺序该加载哪一张（寄存，load_idx 在 IG_RUN 里不变）
reg              seq_nx_valid;
reg  [31:0]      lut_cluster_r;        // R7b-1 时序：cluster_lut / size_lut(load_idx) 每拍预先寄存（原来 load_idx -> 压紧选择 -> load_cluster 一拍走完，-0.16~-2.6ns）
reg  [31:0]      lut_size_r;
reg  [1:0]       ig_start_arm;         // IG_START 第 3 拍起才取 lut_*_r（R8-0a：选择拆成两级，load_idx 更新后第 2 拍才有效）
reg  [2:0]       nth_r0, nth_r1, nth_r2, nth_r3, nth_r4;   // R8-0a 时序：bank n 放的是 PIC 几（压紧序号，寄存）
reg  [2:0]       lut_src_r;            // R8-0a：load_idx 对应扫描器里第几个资源（0~4 = PIC1~5，5 = PIC6）
reg              ig_next_valid;        // IG_GAP 之后还有没有要加载的
reg  [7:0]       decode_error_r;
reg  [7:0]       crc_at_start;         // 花屏修复：本张图开始加载时的 CRC 错误计数
// 扇区重放缓冲已经在扇区级重读过；这里只看救不回来的扇区（crc_fail_cnt），被救回的不再整张重读
wire             crc_bad = (crc_fail_cnt != crc_at_start) || (crc_fail_cnt == 8'hff);

// 诊断：加载耗时计时
reg [3:0]        tick_cnt;             // 数 1ms 节拍到 10
reg [11:0]       load_time_bcd;

// 诊断：本次加载走到了哪一步
wire [2:0]       rd_state;             // bmp_read 内部状态
wire [1:0]       sd_stage;             // SD 命令层阶段
reg              seen_write_req;       // bmp_read 已过文件头校验
reg              seen_load_data;       // 已进入读像素阶段
reg  [2:0]       rd_state_q;           // bmp_read 上一拍的状态（判断“读像素 -> 空闲”）
always @(posedge clk or posedge rst) begin
    if (rst)
        rd_state_q <= 3'd0;
    else
        rd_state_q <= rd_state;
end

// bmp_read 的 SDRAM 写请求握手：loader 在 load_start 时就已准备好接收像素，直接回环应答
wire             write_req;
wire             write_req_ack = write_req;

assign state_code   = (fs_scan_busy && state_code_i == 4'd1) ? 4'd2 : state_code_i;
assign sd_ready     = sd_init_done;
assign boot_done    = (ig_state == IG_DONE);
assign loading      = load_busy;
assign loader_image_index  = load_idx;
assign loader_pixel_valid  = bmp_data_wr_en;
assign loader_pixel_rgb    = bmp_data;
assign loader_decode_error = decode_error_r;

// ---------- 扫描结果按 PIC1~5 顺序压紧 ----------
wire [5:0]  scan_resource_valid;
wire [31:0] res_cluster0, res_cluster1, res_cluster2, res_cluster3, res_cluster4, res_cluster5;
wire [31:0] res_size0, res_size1, res_size2, res_size3, res_size4, res_size5;
// 第 n 个（从 0 数）找到的文件是 PIC 几（0~4）；超出找到的张数时结果无所谓（img_found_count 会挡住）
function [2:0] nth_found;
    input [4:0] v;
    input [2:0] n;
    integer i, c;
    begin
        nth_found = 3'd0;
        c = 0;
        for (i = 0; i < 5; i = i + 1)
            if (v[i]) begin
                if (c == n) nth_found = i;
                c = c + 1;
            end
    end
endfunction

// 扫描器第 i 个资源（0~4 = PIC1~5，5 = PIC6）的起始簇号 / 文件大小
function [31:0] res_cluster_sel;
    input [2:0] i;
    begin
        case (i)
            3'd0: res_cluster_sel = res_cluster0;
            3'd1: res_cluster_sel = res_cluster1;
            3'd2: res_cluster_sel = res_cluster2;
            3'd3: res_cluster_sel = res_cluster3;
            3'd4: res_cluster_sel = res_cluster4;
            default: res_cluster_sel = res_cluster5;
        endcase
    end
endfunction

function [31:0] res_size_sel;
    input [2:0] i;
    begin
        case (i)
            3'd0: res_size_sel = res_size0;
            3'd1: res_size_sel = res_size1;
            3'd2: res_size_sel = res_size2;
            3'd3: res_size_sel = res_size3;
            3'd4: res_size_sel = res_size4;
            default: res_size_sel = res_size5;
        endcase
    end
endfunction

function [2:0] nth_sel;
    input [2:0] n;
    begin
        case (n)
            3'd0: nth_sel = nth_r0;
            3'd1: nth_sel = nth_r1;
            3'd2: nth_sel = nth_r2;
            3'd3: nth_sel = nth_r3;
            default: nth_sel = nth_r4;
        endcase
    end
endfunction

// 当前这张之后加载哪一张：轮播图还有 -> 下一个 bank；轮播图加载完 -> PIC6（bank5，扫描到才加载）；PIC6 之后结束
always @(posedge clk) begin
    if (load_idx == 3'd5) begin
        seq_nx_idx   <= 3'd5;
        seq_nx_valid <= 1'b0;
    end else if (load_idx + 3'd1 < img_found_count) begin
        seq_nx_idx   <= load_idx + 3'd1;
        seq_nx_valid <= 1'b1;
    end else begin
        seq_nx_idx   <= 3'd5;
        seq_nx_valid <= found_mask[5];
    end
end

// R8-0a 时序：原来 resource_valid -> 压紧（nth_found）-> 4 选 1 -> 按 load_idx 5 选 1 一拍走完（-0.3~-1.0ns），拆成三级寄存：
//   ① 压紧序号（扫描结果不变时恒定）② load_idx 对应哪个资源 ③ 簇号 / 大小
always @(posedge clk) begin
    nth_r0        <= nth_found(scan_resource_valid[4:0], 3'd0);
    nth_r1        <= nth_found(scan_resource_valid[4:0], 3'd1);
    nth_r2        <= nth_found(scan_resource_valid[4:0], 3'd2);
    nth_r3        <= nth_found(scan_resource_valid[4:0], 3'd3);
    nth_r4        <= nth_found(scan_resource_valid[4:0], 3'd4);
    lut_src_r     <= (load_idx == 3'd5) ? 3'd5 : nth_sel(load_idx);
    lut_cluster_r <= res_cluster_sel(lut_src_r);
    lut_size_r    <= res_size_sel(lut_src_r);
    ig_start_arm  <= {ig_start_arm[0], ig_state == IG_START};
end

// 第8课：上电加载流程。扫描完成后按 bank0 -> bank4 依次加载找到的轮播图（最后加载 PIC6 到 bank5），每张：
//   同时启动 bmp_read（读文件、解析、拼像素）和 media_frame_loader（收像素、burst 写 SDRAM 的 bank n）；
//   loader 报 load_done：memory_error == 0 成功；否则失败，重试 1 次，还失败就跳过这张（bank 不标记完成）。
//   bmp_read 报错 / 加载超时都通过 loader_decode_error 让 loader 立即结束。
// 全部结束后等 SDRAM 写 CDC 排空，再打开显示：从此只有读、没有写，读写不会同时争用 SDRAM。
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        loader_load_start     <= 1'b0;
        loader_frame_commit   <= 1'b0;
        decode_error_r        <= 8'd0;
        crc_at_start          <= 8'd0;
        cdc_clear             <= 1'b0;
        load_cluster          <= 32'd0;
        load_file_size        <= 32'd0;
        scan_kicked           <= 1'b0;
        scan_done             <= 1'b0;
        img_found_count       <= 3'd0;
        load_idx              <= 3'd0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 14'd0;
        load_abort            <= 1'b0;
        retry_count           <= 2'd0;
        load_giveup           <= 1'b0;
        load_commit           <= 1'b0;
        display_valid         <= 1'b0;
        ig_state              <= IG_WAIT;
        ig_cnt                <= 10'd0;
        ig_next_idx           <= 3'd0;
        ig_next_valid         <= 1'b0;
        found_mask            <= 6'd0;
        giveup_mask           <= 6'd0;
        emg_ok                <= 1'b0;
        loaded_any            <= 1'b0;
        hot                   <= 1'b0;
        ig_after              <= 1'b0;
        sv_start              <= 1'b0;
        sv_wait               <= 1'b0;
    end else begin
        scan_start_pulse    <= 1'b0;
        sv_start            <= 1'b0;
        load_start_pulse    <= 1'b0;
        loader_load_start   <= 1'b0;
        loader_frame_commit <= 1'b0;
        decode_error_r      <= 8'd0;
        load_abort          <= 1'b0;
        load_giveup         <= 1'b0;
        load_commit         <= 1'b0;

        if (!sd_init_done && hot) begin
            // R4 热恢复：SD 层在重新初始化，显示照常（图片在 SDRAM 里），只把扫描标记清掉，初始化好后重新扫描
            scan_kicked           <= 1'b0;
            scan_done             <= 1'b0;
            ig_state              <= IG_HOT;
        end else if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            scan_done             <= 1'b0;
            found_mask            <= 6'd0;
            giveup_mask           <= 6'd0;
            emg_ok                <= 1'b0;
            loaded_any            <= 1'b0;
            img_found_count       <= 3'd0;
            load_idx              <= 3'd0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 14'd0;
            retry_count           <= 2'd0;
            cdc_clear             <= 1'b0;
            display_valid         <= 1'b0;
            sv_wait               <= 1'b0;
            ig_state              <= IG_WAIT;
        end else begin
            // 上电后自动发起一次 FAT32 卷扫描
            // 第5课 2.2 第三步：等 SDRAM 初始化完成后才启动扫描
            if (!scan_kicked && bmp_ready && sdram_init_done && scanner_rst_n) begin
                scan_start_pulse <= 1'b1;
                scan_kicked      <= 1'b1;
                scan_done        <= 1'b0;
                if (!hot) begin
                    display_valid <= 1'b0;
                    ig_state      <= IG_WAIT;
                end
            end

            // 每张图的加载超时（例如读卡卡死）
            if (load_busy) begin
                if (load_timeout_cnt > LOAD_TIMEOUT_MS) begin
                    load_timeout_cnt <= 14'd0;
                    load_abort       <= 1'b1;
                    decode_error_r   <= 8'h02;           // 让 loader 结束本次加载
                end else if (ms_tick) begin
                    load_timeout_cnt <= load_timeout_cnt + 14'd1;
                end
            end else begin
                load_timeout_cnt <= 14'd0;
            end

            // bmp_read 报错：让 loader 结束本次加载
            if (load_busy && load_error)
                decode_error_r <= {5'd0, bmp_error};

            // bmp_read 读完一张图（从读像素回到空闲）：通知 loader 像素已全部送出
            if (load_busy && rd_state_q == 3'd4 && bmp_ready)
                loader_frame_commit <= 1'b1;

            case (ig_state)
                IG_WAIT: begin
                    // 第6课：卷扫描结束，缓存找到的 PIC1~5.BMP 的起始簇号和文件大小。
                    // 缺图时按 PIC1~5 顺序压紧（例如缺 PIC3：bank0~3 = PIC1/PIC2/PIC4/PIC5）；PIC6 固定 bank5
                    if (fs_scan_done) begin
                        scan_done       <= 1'b1;
                        found_mask      <= scan_resource_valid;
                        img_found_count <= {2'b00, scan_resource_valid[0]} + {2'b00, scan_resource_valid[1]} +
                                           {2'b00, scan_resource_valid[2]} + {2'b00, scan_resource_valid[3]} +
                                           {2'b00, scan_resource_valid[4]};
                        load_idx     <= (scan_resource_valid[4:0] != 5'd0) ? 3'd0 : 3'd5;
                        retry_count  <= 2'd0;
                        // 一张都没找到：不打开显示（数码管显示 F + fs_error）
                        ig_after     <= (scan_resource_valid != 6'd0);
                        ig_cnt       <= 10'd0;
                        ig_state     <= IG_SAVE;
                    end
                end

                IG_SAVE: begin
                    // R8-4a：存档 LBA 扫描完成后第 12 拍才算好，等 16 拍再发起；没有有效 SAVE.BIN 就直接往下走
                    if (ig_cnt != 10'd16)
                        ig_cnt <= ig_cnt + 10'd1;
                    if (ig_cnt == 10'd16 && !sv_busy) begin
                        if (save_lba_ok && !arb_sector_busy && !sv_wait) begin
                            sv_start <= 1'b1;
                            sv_wait  <= 1'b1;
                        end else if (!save_lba_ok || sv_end) begin
                            sv_wait  <= 1'b0;
                            ig_state <= ig_after ? IG_START : IG_DONE;
                        end
                    end
                end

                IG_START: begin
                    if (bmp_ready && !loader_load_done && ig_start_arm[1]) begin
                        load_cluster      <= lut_cluster_r;
                        load_file_size    <= lut_size_r;
                        load_start_pulse  <= 1'b1;
                        loader_load_start <= 1'b1;
                        load_busy         <= 1'b1;
                        crc_at_start      <= crc_fail_cnt;
                        ig_state          <= IG_RUN;
                    end
                end

                IG_RUN: begin
                    if (loader_load_done) begin
                        load_busy <= 1'b0;
                        ig_cnt    <= 10'd0;
                        ig_state  <= IG_GAP;
                        if (loader_memory_error == 8'd0 && crc_bad && retry_count < MAX_RETRIES) begin
                            // 花屏修复：像素写全了，但加载期间有扇区 CRC 校验错（读卡错位，图上会有杂点 / 错位）。
                            // 重读一次；第二次仍有 CRC 错就照常使用（防止 CRC 误报时图片永远加载不上）
                            retry_count   <= retry_count + 2'd1;
                            ig_next_idx   <= load_idx;
                            ig_next_valid <= 1'b1;
                        end else if (loader_memory_error == 8'd0) begin
                            // 成功：下一张
                            // 显示只在至少一张轮播图（PIC1~5）成功后打开；PIC6 成功只记 emg_ok
                            load_commit   <= 1'b1;
                            if (load_idx == 3'd5) emg_ok <= 1'b1;
                            else                  loaded_any <= 1'b1;
                            retry_count   <= 2'd0;
                            ig_next_idx   <= seq_nx_idx;
                            ig_next_valid <= seq_nx_valid;
                        end else begin
                            load_abort <= 1'b1;               // 停掉 bmp_read（可能还在读）
                            cdc_clear  <= 1'b1;
                            if (retry_count < MAX_RETRIES) begin
                                // 重试同一张（可能是 SD 卡瞬时错误）
                                retry_count   <= retry_count + 2'd1;
                                ig_next_idx   <= load_idx;
                                ig_next_valid <= 1'b1;
                            end else begin
                                // 重试失败，跳过这张坏图
                                retry_count   <= 2'd0;
                                load_giveup   <= 1'b1;
                                giveup_mask[load_idx] <= 1'b1;
                                ig_next_idx   <= seq_nx_idx;
                                ig_next_valid <= seq_nx_valid;
                            end
                        end
                    end
                end

                IG_GAP: begin
                    // 64 拍间隔：前 16 拍保持 cdc_clear，让 CDC 两侧的复位同步器都完成复位和释放
                    ig_cnt <= ig_cnt + 10'd1;
                    if (ig_cnt == 10'd15)
                        cdc_clear <= 1'b0;
                    if (ig_cnt == 10'd63) begin
                        ig_cnt <= 10'd0;
                        if (ig_next_valid) begin
                            load_idx <= ig_next_idx;
                            ig_state <= IG_START;
                        end else begin
                            ig_state <= IG_DRAIN;
                        end
                    end
                end

                IG_DRAIN: begin
                    // 最后一个 128 字 burst 从 CDC 写进 SDRAM 要约 1us；先等 1000 拍再看 CDC 是否空
                    if (ig_cnt != 10'd1000)
                        ig_cnt <= ig_cnt + 10'd1;
                    else if (cdc_idle)
                        ig_state <= IG_DONE;
                end

                IG_DONE: begin
                    // R4：一张都没加载成功就不打开显示（中间显示故障原因，隔 RETRY_MS 自动重试）
                    display_valid <= loaded_any;
                end

                IG_HOT: begin
                    // 重新扫描完：找回 MUSIC.WAV，回到 IG_DONE（SD 口重新交给 WAV 播放器）
                    if (fs_scan_done) begin
                        scan_done <= 1'b1;
                        hot       <= 1'b0;
                        ig_state  <= IG_DONE;
                    end
                end

                default: ig_state <= IG_WAIT;
            endcase

            if (hot_start)
                hot <= 1'b1;
        end
    end
end

// 第11课：MUSIC.WAV 的起始扇区 = 数据区 + (簇号-2) x 每簇扇区数 + 1（跳过 512 字节的 WAV 头）。
// wav_stream_player 按连续扇区读，所以 MUSIC.WAV 必须连续存放（格式化后最先拷入即可）
reg [2:0] music_spc_shift;
always @(*) begin
    case (scanner_spc)
        8'd2:   music_spc_shift = 3'd1;
        8'd4:   music_spc_shift = 3'd2;
        8'd8:   music_spc_shift = 3'd3;
        8'd16:  music_spc_shift = 3'd4;
        8'd32:  music_spc_shift = 3'd5;
        8'd64:  music_spc_shift = 3'd6;
        8'd128: music_spc_shift = 3'd7;
        default: music_spc_shift = 3'd0;
    endcase
end
// R7a 时序：扫描器输出在 scan_done 之后保持不变，起始扇区分几级寄存预先算好，锁存推迟（原来一拍算完 8 级逻辑，-1.1ns）
// R8-5b 资源：(簇号 - 2) << 每簇扇区数 改成扫描完成后每拍移 1 位（原来 32 位桶形移位器），锁存推迟到第 12 拍
reg [31:0] mlba_ds1, mlba_off, mlba_sum;
reg [2:0]  mlba_n;
reg [23:0] scan_done_d;               // R9：第 12 拍锁存 MUSIC，同一套移位 / 加法再给 GUIDE 用，第 24 拍锁存 GUIDE
always @(posedge clk) begin
    mlba_ds1 <= scanner_data_start + 32'd1;
    mlba_sum <= mlba_ds1 + mlba_off;
    if (fs_scan_done) begin
        mlba_off <= scan_music_cluster - 32'd2;
        mlba_n   <= music_spc_shift;
    end else if (scan_done_d[11]) begin
        mlba_off <= {4'd0, scan_guide_cluster} - 32'd2;
        mlba_n   <= music_spc_shift;
    end else if (mlba_n != 3'd0) begin
        mlba_off <= {mlba_off[30:0], 1'b0};
        mlba_n   <= mlba_n - 3'd1;
    end
end
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_done_d     <= 24'd0;
        music_found     <= 1'b0;
        music_start_lba <= 32'd0;
        music_sectors   <= 32'd0;
    end else if (!sd_init_done || scan_start_pulse) begin
        scan_done_d     <= 24'd0;
        music_found     <= 1'b0;
    end else begin
        scan_done_d     <= {scan_done_d[22:0], fs_scan_done};
        if (scan_done_d[11]) begin
            music_found     <= scan_music_valid && (scan_music_size > 32'd1024) && (scan_music_cluster >= 32'd2);
            music_start_lba <= mlba_sum;
            music_sectors   <= (scan_music_size - 32'd512) >> 9;
        end
    end
end

// R9：GUIDE.WAV 的数据起点（同 MUSIC.WAV：数据区 + 1 + (簇号-2) x 每簇扇区数），借 MUSIC 那套移位 / 加法，第 24 拍锁存
always @(posedge clk or posedge rst) begin
    if (rst) begin
        guide_found <= 1'b0;  guide_lba <= 32'd0;
    end else if (!sd_init_done || scan_start_pulse)
        guide_found <= 1'b0;
    else if (scan_done_d[23]) begin
        guide_found <= scan_guide_valid && (scan_guide_cluster >= 28'd2);
        guide_lba   <= mlba_sum;
    end
end
// R9：位置条存 SAVE.BIN 第 2、3 扇区：文件 >= 1536 字节、每簇 >= 4 扇区（前 3 个扇区连续，在同一簇里）才读 / 写
reg loc_ok;
always @(posedge clk) loc_ok <= scan_save_big && (music_spc_shift >= 3'd2);

// R8-4a：SAVE.BIN 第一个扇区的 LBA = 数据区 + (簇号-2) x 每簇扇区数（和 MUSIC.WAV 一样每拍移 1 位）。
//   簇号必须在 2 ~ max_cluster-1 内才认（R8-4b 写卡只写这一个地址）
reg [31:0] slba_off;
reg [2:0]  slba_n;
reg [31:0] save_lba;
always @(posedge clk) begin
    save_lba <= scanner_data_start + slba_off;
    if (fs_scan_done) begin
        slba_off <= {4'd0, scan_save_cluster} - 32'd2;
        slba_n   <= music_spc_shift;
    end else if (slba_n != 3'd0) begin
        slba_off <= {slba_off[30:0], 1'b0};
        slba_n   <= slba_n - 3'd1;
    end
end
always @(posedge clk or posedge rst) begin
    if (rst)
        save_lba_ok <= 1'b0;
    else if (!sd_init_done || scan_start_pulse)
        save_lba_ok <= 1'b0;
    else if (scan_done_d[1])               // 时序：比较结果先寄存（sv_c_*），扫描完成后第 2 拍再合并
        save_lba_ok <= sv_c_v & sv_c_lo & sv_c_hi;
end
reg sv_c_v, sv_c_lo, sv_c_hi;
always @(posedge clk) begin
    sv_c_v  <= scan_save_valid;
    sv_c_lo <= (scan_save_cluster >= 28'd2);
    sv_c_hi <= ({4'd0, scan_save_cluster} < scanner_max_cluster);
end

// 存档读：收前 32 字节，前 25 字节移进 save_dat，32 字节异或必须为 0；读不完 1 秒超时放弃
//   存档格式见 doc/R8-4_方案.md 第 3 节：0~3 "CPRS"，4 版本 1，31 校验（前 31 字节异或）
//   R9：第 25 字节 bit0 = 1 表示第 2、3 扇区存着急救位置条点阵（512x16 = 1024 字节），校验对且 loc_ok 时接着读进位置点阵
reg [7:0]  sv_x;
reg [9:0]  sv_ms;
reg [1:0]  sv_ph;                      // R9：正在读第几个扇区 0 / 1 / 2
reg [31:0] x_lba;                      //   存档读 / 写当前扇区（读只在 IG_SAVE、写只在 IG_DONE，共用；发起时 = save_lba，换扇区 +1）
reg        sv_sh;                      // R9 时序：下一拍把 sv_b 移进 save_dat
reg [7:0]  sv_b;
reg        sv_flag;                    //   第 25 字节 bit0
reg        loc_valid;                  //   位置点阵来自 TF 卡 / 串口（写回时第 25 字节 bit0 = 1）
reg        ld_we;                      //   开机读卡写位置点阵
reg [9:0]  ld_addr;
reg [7:0]  ld_data;
// R9 时序：存档头检查先寄存（save_dat 读完第 1 扇区后就不变；sv_chk 是读完后的下一拍，这时 sv_ok0 已经是新值）
reg        sv_ok0;
always @(posedge clk) sv_ok0 <= (save_dat[31:0] == {"S", "R", "P", "C"}) && (save_dat[39:32] == 8'd1) && (sv_x == 8'd0);
assign     sv_end  = sv_end_r;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sv_on <= 1'b0;  sv_req <= 1'b0;  sv_chk <= 1'b0;  sv_end_r <= 1'b0;
        sv_x <= 8'd0;  sv_ms <= 10'd0;  save_ld <= 1'b0;  save_dat <= 200'd0;  sv_rd_ok <= 1'b0;
        sv_sh <= 1'b0;  sv_b <= 8'd0;
        sv_ph <= 2'd0;  sv_flag <= 1'b0;  ld_we <= 1'b0;  ld_addr <= 10'd0;  ld_data <= 8'd0;  loc_valid <= 1'b0;
    end else begin
        if (!sd_init_done && !hot)
            sv_rd_ok <= 1'b0;
        else if (sv_on && sv_ph == 2'd0 && arb_sector_done)
            sv_rd_ok <= 1'b1;
        sv_req   <= 1'b0;
        sv_end_r <= 1'b0;
        save_ld  <= 1'b0;
        // R9 时序：save_dat 200 位移位的使能先寄存，晚一拍移（原来 字节号 -> 比较 -> 使能扇出 113，-0.1~-0.4ns）。
        //   第 24 字节之后还有 480 多个字节才到 sector_done，sv_ok0 / save_ld 用的时候早就移完了
        sv_sh <= sv_on && arb_sector_valid && sv_ph == 2'd0 && arb_sector_byte_index[8:5] == 4'd0 && arb_sector_byte_index[4:0] < 5'd25;
        sv_b  <= arb_sector_byte;
        if (sv_sh)
            save_dat <= {sv_b, save_dat[199:8]};
        ld_we    <= 1'b0;
        if (u_loc_ev)
            loc_valid <= 1'b1;
        if (sv_on) begin
            if (arb_sector_valid && sv_ph == 2'd0 && arb_sector_byte_index[8:5] == 4'd0) begin
                sv_x <= sv_x ^ arb_sector_byte;
                if (arb_sector_byte_index[4:0] == 5'd25)
                    sv_flag <= arb_sector_byte[0];
            end
            if (arb_sector_valid && sv_ph != 2'd0) begin
                ld_we   <= 1'b1;
                ld_addr <= {sv_ph[1], arb_sector_byte_index};
                ld_data <= arb_sector_byte;
            end
            if (ms_tick)
                sv_ms <= sv_ms + 10'd1;
            if (arb_sector_done || sv_ms == 10'd1000) begin
                sv_on  <= 1'b0;
                if (sv_ph == 2'd0)
                    sv_chk <= arb_sector_done;
                else if (sv_ph == 2'd1 && arb_sector_done) begin
                    sv_on  <= 1'b1;  sv_req <= 1'b1;  sv_ms <= 10'd0;  sv_ph <= 2'd2;   // 接着读第 3 扇区
                end else begin
                    loc_valid <= arb_sector_done;                                         // 第 3 扇区读完：位置条来自 TF 卡
                    sv_end_r  <= 1'b1;
                end
                if (sv_ph == 2'd0)
                    sv_end_r <= !arb_sector_done;
            end
        end else if (sv_start) begin
            sv_on  <= 1'b1;
            sv_req <= 1'b1;
            sv_x   <= 8'd0;
            sv_ms  <= 10'd0;
            sv_ph  <= 2'd0;
        end
        if (sv_chk) begin
            sv_chk   <= 1'b0;
            save_ld  <= sv_ok0;
            if (sv_ok0 && sv_flag && loc_ok) begin
                sv_on <= 1'b1;  sv_req <= 1'b1;  sv_ms <= 10'd0;  sv_ph <= 2'd1;          // 读第 2 扇区
            end else
                sv_end_r <= 1'b1;
        end
    end
end
// 位置点阵写口合并（开机读卡和串口不会同时发生）；写回时从 emg_overlay 的位置点阵 RAM 第二个口读（不另存副本，省 1 块 BRAM）
always @(posedge clk) begin
    loc_we   <= ld_we | u_loc_we;
    loc_addr <= ld_we ? ld_addr : u_loc_addr;
    loc_data <= ld_we ? ld_data : u_loc_data;
end
reg  [9:0] lc_ra;
wire [7:0] lc_q = loc_q;
assign     loc_ra = lc_ra;

// R8-4b：写卡。等 SD 口空闲（占住后再连续空 32 拍）-> sd_sec_write 拉高（读写层先看写）-> 第一次要数据时放下，
//   每次 data_req 下一拍给一个字节（前 31 字节按字节号从 save_img 选，第 31 字节 = 前 31 字节边发边异或的校验，后面是 0）-> sd_sec_write_end 结束。
//   R8-4b 资源：原来先把 save_img 复制进 256 位移位寄存器、校验用 20 字节异或树，改成选字节 + 累加异或（约省 250 LUT）
//   500ms 没写完（卡拔了 / 写保护 / 卡一直忙）：放弃，本次开机不再写，按拔卡复位 SD 层（热恢复，显示不关）
//   R9：电脑串口改了位置条（u_loc_ev）-> 连写 3 个扇区（第 1 扇区第 25 字节 bit0 = 1，第 2、3 扇区 = 位置点阵）；
//   平时写设置只写第 1 扇区（第 25 字节 bit0 照样带上 loc_valid，位置点阵不动）
reg  [1:0]   wr_st;
reg          wr_pend, wr_dead, sd_wr;
reg          wr_lpend, wr_lall;        // R9：位置条待写 / 这一次连写 3 个扇区
reg  [1:0]   wr_sec;                   //   正在写第几个扇区
wire         lv_w = loc_valid & loc_ok;
wire [7:0]   wr_s0 = (wr_n[9:5] != 5'd0) ? 8'd0 : (wr_n[4:0] == 5'd31) ? wr_x :
                     (wr_n[4:0] == 5'd25) ? {save_img[207:201], save_img[200] | lv_w} : save_img[{wr_n[4:0], 3'b000} +: 8];
reg  [4:0]   wr_gap;
reg  [9:0]   wr_ms;
reg  [9:0]   wr_n;                     // 已送出几个字节
reg  [7:0]   wr_x;                     // 已送出字节的异或
reg  [7:0]   wr_byte;
wire         sd_wr_req, sd_wr_end;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        wr_st <= 2'd0;  wr_pend <= 1'b0;  wr_dead <= 1'b0;  sd_wr <= 1'b0;  wr_own <= 1'b0;
        wr_lpend <= 1'b0;  wr_lall <= 1'b0;  wr_sec <= 2'd0;  lc_ra <= 10'd0;
        wr_gap <= 5'd0;  wr_ms <= 10'd0;  wr_n <= 10'd0;  wr_x <= 8'd0;  wr_byte <= 8'd0;  wr_tmo <= 1'b0;  save_fail <= 1'b0;
    end else begin
        wr_tmo    <= 1'b0;
        save_fail <= 1'b0;
        if (wr_st != 2'd0 && !sd_init_done) begin
            wr_st <= 2'd0;  wr_own <= 1'b0;  sd_wr <= 1'b0;        // 写的时候 SD 层被复位（拔卡）：本次作废，请求留着
        end else case (wr_st)
            2'd0: if ((wr_pend || wr_lpend) && ig_state == IG_DONE && !hot && save_lba_ok && sv_rd_ok && !wr_dead && !probe_on) begin
                wr_own  <= 1'b1;
                wr_gap  <= 5'd0;
                wr_st   <= 2'd1;
                wr_sec  <= 2'd0;
                wr_lall <= wr_lpend && loc_ok;
                wr_lpend <= 1'b0;
            end
            2'd1: begin
                if (arb_sector_busy)
                    wr_gap <= 5'd0;
                else if (wr_gap != 5'd31)
                    wr_gap <= wr_gap + 5'd1;
                else begin
                    if (wr_sec == 2'd0) wr_pend <= 1'b0;
                    wr_n    <= 10'd0;
                    wr_x    <= 8'd0;
                    sd_wr   <= 1'b1;
                    wr_ms   <= 10'd0;
                    wr_st   <= 2'd2;
                end
            end
            default: begin
                if (sd_wr_req) begin
                    sd_wr   <= 1'b0;
                    wr_byte <= (wr_sec == 2'd0) ? wr_s0 : lc_q;
                    wr_x    <= wr_x ^ wr_s0;
                    wr_n    <= wr_n + 10'd1;
                end
                lc_ra <= {wr_sec[1], wr_n[8:0]};          // 位置点阵副本：第 2 扇区 = 0~511，第 3 扇区 = 512~1023
                if (ms_tick)
                    wr_ms <= wr_ms + 10'd1;
                if (sd_wr_end) begin
                    if (wr_lall && wr_sec != 2'd2) begin  // 接着写下一个扇区
                        wr_sec <= wr_sec + 2'd1;
                        wr_gap <= 5'd0;
                        wr_st  <= 2'd1;
                    end else begin
                        wr_own <= 1'b0;
                        wr_st  <= 2'd0;
                    end
                end else if (wr_ms == 10'd500) begin
                    wr_own    <= 1'b0;
                    sd_wr     <= 1'b0;
                    wr_dead   <= 1'b1;
                    wr_tmo    <= 1'b1;
                    save_fail <= 1'b1;
                    wr_st     <= 2'd0;
                end
            end
        endcase
        if (save_req)
            wr_pend <= 1'b1;
        if (u_loc_ev)
            wr_lpend <= 1'b1;
    end
end

// R9 资源：存档读 / 写共用一个当前扇区寄存器 x_lba（读只在 IG_SAVE、写只在 IG_DONE，不会同时）。
//   发起时装 save_lba；读第 2 / 3 扇区、连写下一个扇区时 +1，和发出请求的那一拍同时更新
wire wr_go  = (wr_st == 2'd0) && (wr_pend || wr_lpend) && ig_state == IG_DONE && !hot && save_lba_ok && sv_rd_ok && !wr_dead && !probe_on;
wire wr_adv = (wr_st[1] && sd_init_done && sd_wr_end && wr_lall && wr_sec != 2'd2);
wire sv_adv = (sv_on && sv_ph == 2'd1 && arb_sector_done) || (sv_chk && sv_ok0 && sv_flag && loc_ok);
always @(posedge clk)
    if (sv_start || wr_go)    x_lba <= save_lba;
    else if (sv_adv || wr_adv) x_lba <= x_lba + 32'd1;

// 诊断：每次加载从启动到提交（或超时放弃）的耗时，BCD 计数便于直接上数码管
function [11:0] bcd3_inc;
    input [11:0] v;
    begin
        if (v == 12'h999)
            bcd3_inc = v;                                  // 封顶 9.99s
        else if (v[3:0] != 4'd9)
            bcd3_inc = {v[11:4], v[3:0] + 4'd1};
        else if (v[7:4] != 4'd9)
            bcd3_inc = {v[11:8], v[7:4] + 4'd1, 4'd0};
        else
            bcd3_inc = {v[11:8] + 4'd1, 8'h00};
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        tick_cnt       <= 4'd0;
        load_time_bcd  <= 12'h000;
        last_load_time <= 12'h000;
        last_load_err  <= 1'b0;
    end else begin
        if (load_start_pulse) begin
            tick_cnt      <= 4'd0;
            load_time_bcd <= 12'h000;
        end else if (load_busy && ms_tick) begin
            if (tick_cnt == 4'd9) begin
                tick_cnt      <= 4'd0;
                load_time_bcd <= bcd3_inc(load_time_bcd);
            end else begin
                tick_cnt <= tick_cnt + 4'd1;
            end
        end

        if (load_commit) begin
            last_load_time <= load_time_bcd;
            last_load_err  <= 1'b0;
        end else if (load_giveup) begin
            last_load_time <= load_time_bcd;
            last_load_err  <= 1'b1;
        end else if (load_abort) begin
            last_load_time <= load_time_bcd;
            last_load_err  <= 1'b1;
        end
    end
end

// 诊断：超时那一刻卡在哪
//   abort 代码  含义
//     1         文件头校验没通过（没发 SDRAM 写请求就回到空闲）
//     2         卡在读文件头扇区（SD 读取）
//     3         卡在等 SDRAM 写应答
//     4         卡在读像素扇区（SD 读取）
//     5         像素已全部送出，SDRAM 没写完整帧
//     6         已拿到 SDRAM 应答但没进入读像素，状态机跳飞（跨时钟域异常的特征）
//     7         （第6课起不再出现：扫描已移出 bmp_read）
//     9/A/B/C   第4课：重试 1 次仍失败、已跳过（9 BMP 头校验失败 A SD 读超时 B 像素截断 C FAT 链错误）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        seen_write_req <= 1'b0;
        seen_load_data <= 1'b0;
        abort_code     <= 4'd0;
        abort_sd_stage <= 2'd0;
    end else begin
        if (load_start_pulse) begin
            seen_write_req <= 1'b0;
            seen_load_data <= 1'b0;
        end else begin
            if (write_req)
                seen_write_req <= 1'b1;
            if (rd_state == 3'd4)
                seen_load_data <= 1'b1;
        end

        if (load_giveup) begin
            abort_code     <= {1'b1, bmp_error};
            abort_sd_stage <= sd_stage;
        end else if (load_abort) begin
            abort_sd_stage <= sd_stage;
            case (rd_state)
                3'd1:    abort_code <= 4'd7;
                3'd2:    abort_code <= 4'd2;
                3'd3:    abort_code <= 4'd3;
                3'd4:    abort_code <= 4'd4;
                default: abort_code <= seen_load_data ? 4'd5 : (seen_write_req ? 4'd6 : 4'd1);
            endcase
        end
    end
end

//=== 第6课：FAT32 卷扫描器 + 文件流读取器 + 扇区接口适配层 ===

// ---------- 子模块复位：每块一个 reset_sync（第5课），异步压下、同步释放 ----------
// 时序修改（移植时加）：原来 SD 层、扫描器、流读器的复位都是 rst 和别的信号组合后直接当异步复位，
// 一根复位网扇出 555，恢复时间检查 -1.6ns。拆成几个本地同步器，扇出变小，释放也和本时钟沿对齐。
// 释放比原来晚 2 拍，所以扫描启动和文件启动都要等对应模块出复位（scanner_rst_n / file_ready）。
wire sd_blk_crc_err;   // 扇区重放：本扇区 CRC 错
wire sdcore_rst_n;     // sd_card_top + 扇区适配层（看门狗复位时一起复位）
wire scanner_rst_n;    // 卷扫描器（SD 未初始化时保持复位）
wire streamer_rst_n;   // 流读器（bmp_read 的 file_abort 中止）
wire file_abort;
reset_sync u_sdcore_reset   (.clk(clk), .ext_rst_n(~(rst | sd_wd_rst)),  .rst_n_sync(sdcore_rst_n));
reset_sync u_scanner_reset  (.clk(clk), .ext_rst_n(~rst & sd_init_done), .rst_n_sync(scanner_rst_n));
reset_sync u_streamer_reset (.clk(clk), .ext_rst_n(~(rst | file_abort)), .rst_n_sync(streamer_rst_n));

// ---------- 扇区读仲裁（文档 5.4 修改点1/5）：扫描阶段用扫描器，扫描成功后用流读器 ----------
reg         use_streamer;          // 0=用扫描器, 1=用流读器
reg         scan_success;          // 扫描成功标志（至少找到1个文件）

wire        scanner_sector_req;
wire [31:0] scanner_sector_lba;
wire        streamer_sector_req;
wire [31:0] streamer_sector_lba;

reg         arb_sector_req;
reg  [31:0] arb_sector_lba;
wire        arb_sector_busy;
wire        arb_sector_valid;
wire [7:0]  arb_sector_byte;
wire [8:0]  arb_sector_byte_index;
wire        arb_sector_done;
wire [7:0]  arb_sector_error;

// 第11课：四张图加载完（IG_DONE）之后 SD 卡就空闲了，交给 WAV 播放器
// R7b-2 时序：寄存输出（比 ig_state 晚 1 拍；进出 IG_DONE 的那一拍 SD 口上都没有读操作），
// 原来 ig_state -> 比较 -> 扇区仲裁 -> 流读器 sector_lba 使能一拍走完（-0.1~-0.4ns）
reg wav_sd_en_r;
always @(posedge clk or posedge rst) begin
    if (rst) wav_sd_en_r <= 1'b0;
    else     wav_sd_en_r <= (ig_state == IG_DONE);
end
assign wav_sd_enable = wav_sd_en_r;

always @(*) begin
    if (sv_on) begin
        // R8-4a：存档读只在 IG_SAVE 里（扫描器 / 流读器都空闲），优先
        arb_sector_req = sv_req;
        arb_sector_lba = x_lba;
    end else if (wav_sd_enable) begin
        arb_sector_req = wr_own ? 1'b0 : probe_on ? probe_req : wav_sector_req;
        arb_sector_lba = probe_on ? 32'd0 : wav_sector_lba;
    end else if (use_streamer) begin
        arb_sector_req = streamer_sector_req;
        arb_sector_lba = streamer_sector_lba;
    end else begin
        arb_sector_req = scanner_sector_req;
        arb_sector_lba = scanner_sector_lba;
    end
end

// 返回信号按 use_streamer 分别接到扫描器或流读器（另一个看到的 valid/done 恒为 0）
wire scanner_sector_valid  = arb_sector_valid & ~use_streamer & ~wav_sd_enable;
wire scanner_sector_done   = arb_sector_done  & ~use_streamer & ~wav_sd_enable;
wire streamer_sector_valid = arb_sector_valid &  use_streamer & ~wav_sd_enable;
wire streamer_sector_done  = arb_sector_done  &  use_streamer & ~wav_sd_enable;
assign wav_sector_busy       = arb_sector_busy | probe_on | wr_own;
assign wav_sector_valid      = arb_sector_valid & wav_sd_enable & ~probe_on;
assign wav_sector_byte       = arb_sector_byte;
assign wav_sector_byte_index = arb_sector_byte_index;
assign wav_sector_done       = arb_sector_done  & wav_sd_enable & ~probe_on;
assign wav_sector_error      = arb_sector_error;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        use_streamer <= 1'b0;
        scan_success <= 1'b0;
    end else if (!sd_init_done || scan_start_pulse) begin
        // SD 重新初始化 / 重新扫描：切回扫描器
        use_streamer <= 1'b0;
        scan_success <= 1'b0;
    end else if (fs_scan_done) begin
        // 扫描完成：如果至少找到1个文件（resource_valid != 0），标记成功并切换到流读器
        scan_success <= (scan_resource_valid != 6'd0);
        use_streamer <= (scan_resource_valid != 6'd0);  // 只有扫描成功才切换
    end
end

// ---------------- R4：拔卡检测 / 自动恢复 ----------------
// 显示中（IG_DONE）：
//   - SD 空闲 PROBE_MS 且 WAV 播放器没在请求：读一次扇区 0（数据丢弃），所以没放音乐时也能发现拔卡
//   - 一次扇区读持续 LOST_MS 还没完成（拔卡后读卡层会一直重发 CMD17）：tf_lost = 1，复位 SD 层，进 IG_HOT
//   - IG_HOT 里卡插回去、初始化 + 扫描完成：tf_lost = 0，回 IG_DONE，音乐从头放
// 上电失败（没卡由初始化看门狗每 1.5s 重试；格式错 / 没图 / 图全读不出：停在 IG_DONE 且显示没打开）：
//   每 RETRY_MS 复位 SD 层重新来一遍（冷启动，和上电一样）
always @(posedge clk or posedge rst) begin
    if (rst) begin
        busy_cnt <= 12'd0;  idle_cnt <= 12'd0;  retry_cnt <= 12'd0;
        probe_on <= 1'b0;  probe_req <= 1'b0;
        tf_lost <= 1'b0;  tf_recovered <= 1'b0;  sd_reinit_req <= 1'b0;
    end else begin
        probe_req     <= 1'b0;
        sd_reinit_req <= 1'b0;
        tf_recovered  <= 1'b0;
        // 扇区读持续时间
        if (ig_state == IG_DONE && arb_sector_busy)
            busy_cnt <= (busy_cnt >= LOST_MS || !ms_tick) ? busy_cnt : busy_cnt + 12'd1;
        else
            busy_cnt <= 12'd0;
        // 空闲探测
        if (ig_state != IG_DONE || arb_sector_busy || wav_sector_req || probe_on || wr_own)
            idle_cnt <= 12'd0;
        else if (idle_cnt >= PROBE_MS) begin
            idle_cnt  <= 12'd0;
            probe_on  <= 1'b1;
            probe_req <= 1'b1;
        end else if (ms_tick)
            idle_cnt <= idle_cnt + 12'd1;
        if (probe_on && (arb_sector_done || ig_state != IG_DONE))
            probe_on <= 1'b0;
        // 拔卡：复位 SD 层，进热恢复
        if (hot_start) begin
            tf_lost       <= 1'b1;
            sd_reinit_req <= 1'b1;
            busy_cnt      <= 12'd0;
        end
        if (tf_lost && hot && ig_state == IG_HOT && fs_scan_done) begin
            tf_lost      <= 1'b0;
            tf_recovered <= 1'b1;
        end
        // 上电失败：定时重来
        if (sd_init_done && ig_state == IG_DONE && !display_valid && !loading) begin
            if (retry_cnt >= RETRY_MS) begin
                retry_cnt     <= 12'd0;
                sd_reinit_req <= 1'b1;
            end else if (ms_tick)
                retry_cnt <= retry_cnt + 12'd1;
        end else
            retry_cnt <= 12'd0;
    end
end

// ---------- 卷扫描器 ----------
wire [7:0]  scanner_spc;
wire        scan_music_valid;
wire [31:0] scan_music_cluster;
wire [31:0] scan_music_size;
wire [31:0] scanner_fat_start;
wire [31:0] scanner_data_start;
wire [31:0] scanner_max_cluster;
wire        scan_save_valid;
wire [27:0] scan_save_cluster;
wire        scan_save_big, scan_guide_valid;     // R9
wire [27:0] scan_guide_cluster;


fat32_volume_scanner u_scanner (
    .clk                 (clk),
    .rst_n               (scanner_rst_n),         // 官方是高有效复位，新模块是低有效；SD 重新初始化时一并复位
    .scan_start          (scan_start_pulse),
    .scan_busy           (fs_scan_busy),
    .scan_done           (fs_scan_done),
    .fs_error            (fs_error),
    .partition_lba       (),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .resource_valid      (scan_resource_valid),
    .resource0_cluster   (res_cluster0),
    .resource1_cluster   (res_cluster1),
    .resource2_cluster   (res_cluster2),
    .resource3_cluster   (res_cluster3),
    .resource4_cluster   (res_cluster4),
    .resource5_cluster   (res_cluster5),
    .resource0_size      (res_size0),
    .resource1_size      (res_size1),
    .resource2_size      (res_size2),
    .resource3_size      (res_size3),
    .resource4_size      (res_size4),
    .resource5_size      (res_size5),
    .music_valid         (scan_music_valid),
    .music_cluster       (scan_music_cluster),
    .music_size          (scan_music_size),
    .save_valid          (scan_save_valid),
    .save_cluster        (scan_save_cluster),
    .save_big            (scan_save_big),
    .guide_valid         (scan_guide_valid),
    .guide_cluster       (scan_guide_cluster),
    .sector_req          (scanner_sector_req),
    .sector_lba          (scanner_sector_lba),
    .sector_busy         (arb_sector_busy),
    .sector_valid        (scanner_sector_valid),
    .sector_byte         (arb_sector_byte),
    .sector_byte_index   (arb_sector_byte_index),
    .sector_done         (scanner_sector_done),
    .sector_error        (arb_sector_error)
);

// ---------- 文件流读取器 ----------
// bmp_read 用 file_abort 中止它（第 1 遍读够文件头 / 超时 / 上层放弃本次加载）
wire        file_start;
wire        file_busy;
wire        file_ready = streamer_rst_n && !file_busy;   // 流读器已出复位且空闲，可以接受 file_start
wire        file_valid;
wire [7:0]  file_byte;
wire        file_done;
wire [7:0]  file_fs_error;

fat32_file_streamer u_streamer (
    .clk                 (clk),
    .rst_n               (streamer_rst_n),
    .file_start          (file_start),
    .first_cluster       (load_cluster),
    .file_size           (load_file_size),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .file_busy           (file_busy),
    .file_done           (file_done),
    .file_valid          (file_valid),
    .file_byte           (file_byte),
    .file_byte_offset    (),
    .fs_error            (file_fs_error),
    .sector_req          (streamer_sector_req),
    .sector_lba          (streamer_sector_lba),
    .sector_busy         (arb_sector_busy),
    .sector_valid        (streamer_sector_valid),
    .sector_byte         (arb_sector_byte),
    .sector_byte_index   (arb_sector_byte_index),
    .sector_done         (streamer_sector_done),
    .sector_error        (arb_sector_error)
);

// ---------- SD卡接口适配层（对接官方sd_card_top）----------
sd_sector_adapter u_adapter (
    .replay_hold            (bmp_src_hold),       // R8-5a：缩放行缓冲满时暂停扇区重放（只在读像素时）
    .clk                    (clk),
    .rst_n                  (sdcore_rst_n),
    // 新模块侧（接仲裁器输出）
    .sector_req             (arb_sector_req),
    .sector_lba             (arb_sector_lba),
    .sector_busy            (arb_sector_busy),
    .sector_valid           (arb_sector_valid),
    .sector_byte            (arb_sector_byte),
    .sector_byte_index      (arb_sector_byte_index),
    .sector_done            (arb_sector_done),
    .sector_error           (arb_sector_error),
    // 官方sd_card_top侧
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_read_crc_err    (sd_blk_crc_err),
    .crc_retry_cnt          (),
    .crc_fail_cnt           (crc_fail_cnt),
    .crc_trusted            ()
);

// ---------- BMP 头解析 + RGB 拼装 + SDRAM 写握手（数据来自文件流）----------
bmp_read #(
    .CLK_FREQ_HZ            (CLK_FREQ_HZ),
    .OUT_W                  (OUT_W),
    .OUT_H                  (OUT_H)
) bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .pix_ready              (loader_pixel_ready),
    .src_hold               (bmp_src_hold),
    .top_down               (loader_top_down),
    .src_w                  (src_w),
    .src_h                  (src_h),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .file_start             (file_start),
    .file_abort             (file_abort),
    .file_ready             (file_ready),
    .file_valid             (file_valid),
    .file_byte              (file_byte),
    .file_done              (file_done),
    .file_fs_error          (file_fs_error),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .dbg_state              (rd_state),
    .bmp_error              (bmp_error),
    .load_error             (load_error)
);
//=== 第6课修改结束 ===

// R8-5c：每个 bank 记下原图宽高（加载成功那一拍写；之后 IG_GAP 64 拍 load_idx 不变），按当前显示的 bank 查表、寄存一拍输出
reg  [21:0]      wh_tab [0:7];
always @(posedge clk) begin
    if (load_commit)
        wh_tab[load_idx] <= {src_w, src_h};
    cur_wh <= wh_tab[cur_pic];
end

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (~sdcore_rst_n),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (sd_wr),
    .sd_sec_write_addr      (x_lba),
    .sd_sec_write_data      (wr_byte),
    .sd_sec_write_data_req  (sd_wr_req),
    .sd_sec_write_end       (sd_wr_end),
    .dbg_stage              (sd_stage),
    .crc_err_cnt            (crc_err_cnt),
    .rd_retry_cnt           (rd_retry_cnt),
    .blk_crc_err            (sd_blk_crc_err)
);

endmodule

// R8-5a 资源：消抖计时改数 1ms 节拍 tick（ui_key_router 共用一个分频器），原来 24 位时钟计数器
module key_press_debounce #(
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire tick,         // 1ms 单拍
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse,
    output wire button_level  // 消抖后的电平（1=松开，0=按下），供长按检测用
);

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [5:0]  cnt;                       // 单位 1ms

assign button_level = button_stable;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 6'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 6'd0;
        end else if (tick) begin
            if (cnt >= DEBOUNCE_MS - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 6'd0;
            end else begin
                cnt <= cnt + 6'd1;
            end
        end
    end
end

endmodule
