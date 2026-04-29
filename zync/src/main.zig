const std = @import("std");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3_ttf/SDL_ttf.h");
});

const TOTAL_ROWS = 100000;
const TOTAL_COLS = 1000;
const CELL_W: f32 = 100.0;
const CELL_H: f32 = 25.0;
const HEADER_SIZE: f32 = 50.0;
const SB_WIDTH: f32 = 12.0;
const LRU_CAPACITY = 2000;

// Catppuccin Mocha Palette
const CT_BASE = c.SDL_Color{ .r = 30, .g = 30, .b = 46, .a = 255 };
const CT_MANTLE = c.SDL_Color{ .r = 24, .g = 24, .b = 37, .a = 255 };
const CT_SURFACE0 = c.SDL_Color{ .r = 49, .g = 50, .b = 68, .a = 255 };
const CT_TEXT = c.SDL_Color{ .r = 205, .g = 214, .b = 244, .a = 255 };
const CT_LAVENDER = c.SDL_Color{ .r = 180, .g = 190, .b = 254, .a = 255 };
const CT_SUBTEXT0 = c.SDL_Color{ .r = 166, .g = 173, .b = 200, .a = 255 };
const CT_GREEN = c.SDL_Color{ .r = 166, .g = 227, .b = 161, .a = 255 };

fn getSafeWidthText(font: *c.TTF_Font, text: []const u8, max_w: f32) []const u8 {
    if (text.len == 0) return text;
    var tw: i32 = 0;
    var th: i32 = 0;

    // 에러 메시지 기반: font, ptr, length, &tw, &th 총 5개 인자 필요
    _ = c.TTF_GetStringSize(font, text.ptr, text.len, &tw, &th);

    if (@as(f32, @floatFromInt(tw)) <= max_w) return text;

    var current_len = text.len;
    while (current_len > 0) {
        // UTF-8 경계 처리
        while (current_len > 0 and (text[current_len - 1] & 0xc0) == 0x80) : (current_len -= 1) {}
        if (current_len > 0) current_len -= 1;

        // length 인자 자리에 current_len을 바로 넣으면 끝! (버퍼 복사 필요 없음)
        _ = c.TTF_GetStringSize(font, text.ptr, current_len, &tw, &th);
        if (@as(f32, @floatFromInt(tw)) <= max_w) break;
    }
    return text[0..current_len];
}

fn getColName(index: usize, buf: *[16]u8) []const u8 {
    var i = index + 1;
    var pos: usize = 15;
    while (i > 0) {
        pos -= 1;
        const rem = (i - 1) % 26;
        buf[pos] = @as(u8, @intCast(rem)) + 'A';
        i = (i - 1) / 26;
    }
    return buf[pos..15];
}

const CellIndex = struct { r: usize, col: usize };
const ZyncCell = struct {
    raw_input: std.ArrayListUnmanaged(u8) = .{},
    evaluated_display: [128]u8 = [_]u8{0} ** 128,
    display_len: usize = 0,
    pub fn evaluate(self: *ZyncCell) void {
        const len = @min(self.raw_input.items.len, 127);
        @memcpy(self.evaluated_display[0..len], self.raw_input.items[0..len]);
        self.display_len = len;
    }
};

const ZyncSheet = struct {
    cells: std.AutoHashMap(CellIndex, ZyncCell),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) ZyncSheet {
        return .{ .cells = std.AutoHashMap(CellIndex, ZyncCell).init(allocator), .allocator = allocator };
    }
    pub fn getOrCreate(self: *ZyncSheet, r: usize, col: usize) !*ZyncCell {
        const idx = CellIndex{ .r = r, .col = col };
        if (self.cells.getPtr(idx)) |ptr| return ptr;
        try self.cells.put(idx, .{});
        return self.cells.getPtr(idx).?;
    }
};

const LruCache = struct {
    const Node = struct { hash: u64, tex: *c.SDL_Texture, prev: ?*Node = null, next: ?*Node = null };
    map: std.AutoHashMap(u64, *Node),
    head: ?*Node = null,
    tail: ?*Node = null,
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) LruCache {
        return .{ .map = std.AutoHashMap(u64, *Node).init(allocator), .allocator = allocator };
    }
    pub fn fetch(self: *LruCache, ren: *c.SDL_Renderer, font: *c.TTF_Font, text: []const u8, color: c.SDL_Color) !*c.SDL_Texture {
        const hash = std.hash.Wyhash.hash(color.r ^ (@as(u64, color.g) << 8), text);
        if (self.map.get(hash)) |node| {
            self.promote(node);
            return node.tex;
        }
        if (self.map.count() >= LRU_CAPACITY) self.evict();
        const surf = c.TTF_RenderText_Blended(font, text.ptr, text.len, color) orelse return error.Ttf;
        defer c.SDL_DestroySurface(surf);
        const tex = c.SDL_CreateTextureFromSurface(ren, surf) orelse return error.Sdl;
        const new_node = try self.allocator.create(Node);
        new_node.* = .{ .hash = hash, .tex = tex };
        try self.map.put(hash, new_node);
        self.pushHead(new_node);
        return tex;
    }
    fn pushHead(self: *LruCache, node: *Node) void {
        node.next = self.head;
        if (self.head) |h| h.prev = node;
        self.head = node;
        if (self.tail == null) self.tail = node;
    }
    fn promote(self: *LruCache, node: *Node) void {
        if (node == self.head) return;
        if (node.prev) |p| p.next = node.next;
        if (node.next) |n| n.prev = node.prev;
        if (node == self.tail) self.tail = node.prev;
        node.prev = null;
        self.pushHead(node);
    }
    fn evict(self: *LruCache) void {
        const t = self.tail orelse return;
        _ = self.map.remove(t.hash);
        if (t.prev) |p| p.next = null;
        self.tail = t.prev;
        if (t == self.head) self.head = null;
        c.SDL_DestroyTexture(t.tex);
        self.allocator.destroy(t);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.Sdl;
    if (!c.TTF_Init()) return error.Ttf;
    const win = c.SDL_CreateWindow("Zync - Catppuccin Mocha", 1280, 720, c.SDL_WINDOW_RESIZABLE) orelse return error.Win;
    const ren = c.SDL_CreateRenderer(win, null) orelse return error.Ren;
    const font = c.TTF_OpenFont("resources/regular.ttf", 14) orelse return error.Font;

    var sheet = ZyncSheet.init(allocator);
    var lru = LruCache.init(allocator);
    var off_x: f32 = 0;
    var off_y: f32 = 0;
    var sel_r: usize = 0;
    var sel_c: usize = 0;
    var comp_text: [64]u8 = [_]u8{0} ** 64;
    var comp_len: usize = 0;
    var is_drag_v = false;
    var is_drag_h = false;
    var drag_start_offset: f32 = 0;
    var drag_start_mouse: f32 = 0;

    _ = c.SDL_StartTextInput(win);

    main_loop: while (true) {
        var ev: c.SDL_Event = undefined;
        var wi: i32 = 0;
        var hi: i32 = 0;
        _ = c.SDL_GetWindowSize(win, &wi, &hi);
        const win_w = @as(f32, @floatFromInt(wi));
        const win_h = @as(f32, @floatFromInt(hi));
        const view_w = win_w - HEADER_SIZE - SB_WIDTH;
        const view_h = win_h - HEADER_SIZE - SB_WIDTH;
        const full_w = @as(f32, TOTAL_COLS) * CELL_W;
        const full_h = @as(f32, TOTAL_ROWS) * CELL_H;

        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => break :main_loop,
                c.SDL_EVENT_MOUSE_WHEEL => {
                    off_y = @max(0, @min(full_h - view_h, off_y - ev.wheel.y * 75));
                    off_x = @max(0, @min(full_w - view_w, off_x + ev.wheel.x * 75));
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                    const mx = ev.button.x;
                    const my = ev.button.y;
                    if (mx > win_w - SB_WIDTH) {
                        is_drag_v = true;
                        drag_start_mouse = my;
                        drag_start_offset = off_y;
                    } else if (my > win_h - SB_WIDTH) {
                        is_drag_h = true;
                        drag_start_mouse = mx;
                        drag_start_offset = off_x;
                    } else if (mx > HEADER_SIZE and my > HEADER_SIZE) {
                        sel_c = @intFromFloat((mx - HEADER_SIZE + off_x) / CELL_W);
                        sel_r = @intFromFloat((my - HEADER_SIZE + off_y) / CELL_H);
                        comp_len = 0;
                    }
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    is_drag_v = false;
                    is_drag_h = false;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    if (is_drag_v) off_y = @max(0, @min(full_h - view_h, drag_start_offset + ((ev.motion.y - drag_start_mouse) / view_h) * full_h));
                    if (is_drag_h) off_x = @max(0, @min(full_w - view_w, drag_start_offset + ((ev.motion.x - drag_start_mouse) / view_w) * full_w));
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    const cell = try sheet.getOrCreate(sel_r, sel_c);
                    try cell.raw_input.appendSlice(allocator, std.mem.span(ev.text.text));
                    cell.evaluate();
                    comp_len = 0;
                },
                c.SDL_EVENT_TEXT_EDITING => {
                    comp_len = std.mem.len(ev.edit.text);
                    @memcpy(comp_text[0..comp_len], ev.edit.text[0..comp_len]);
                },
                c.SDL_EVENT_KEY_DOWN => switch (ev.key.key) {
                    c.SDLK_BACKSPACE => if (sheet.cells.getPtr(.{ .r = sel_r, .col = sel_c })) |cell| {
                        if (cell.raw_input.items.len > 0) {
                            // UTF-8 가변 길이 문자 삭제 로직
                            var len = cell.raw_input.items.len;

                            // 1. 최소 1바이트는 지워야 함
                            len -= 1;

                            // 2. 지운 바이트가 UTF-8 후속 바이트(10xxxxxx)라면,
                            // 실제 문자의 시작 바이트(11xxxxxx 또는 0xxxxxxx)를 만날 때까지 더 지움
                            while (len > 0 and (cell.raw_input.items[len] & 0xc0) == 0x80) {
                                len -= 1;
                            }

                            // ArrayList의 길이를 조절하여 실제 문자를 완전히 삭제
                            cell.raw_input.shrinkAndFree(allocator, len);
                            cell.evaluate();
                        }
                    },
                    c.SDLK_RETURN, c.SDLK_DOWN => if (sel_r < TOTAL_ROWS - 1) {
                        sel_r += 1;
                        comp_len = 0;
                    },
                    c.SDLK_UP => if (sel_r > 0) {
                        sel_r -= 1;
                        comp_len = 0;
                    },
                    c.SDLK_LEFT => if (sel_c > 0) {
                        sel_c -= 1;
                        comp_len = 0;
                    },
                    c.SDLK_RIGHT => if (sel_c < TOTAL_COLS - 1) {
                        sel_c += 1;
                        comp_len = 0;
                    },
                    else => {},
                },
                else => {},
            }
        }

        _ = c.SDL_SetRenderDrawColor(ren, CT_BASE.r, CT_BASE.g, CT_BASE.b, 255);
        _ = c.SDL_RenderClear(ren);

        const s_col = @as(usize, @intFromFloat(off_x / CELL_W));
        const e_col = @min(TOTAL_COLS, s_col + @as(usize, @intFromFloat(win_w / CELL_W)) + 2);
        const s_row = @as(usize, @intFromFloat(off_y / CELL_H));
        const e_row = @min(TOTAL_ROWS, s_row + @as(usize, @intFromFloat(win_h / CELL_H)) + 2);

        // 1. 일반 셀 렌더링
        for (s_row..e_row) |r| {
            for (s_col..e_col) |col| {
                const x = @as(f32, @floatFromInt(col)) * CELL_W - off_x + HEADER_SIZE;
                const y = @as(f32, @floatFromInt(r)) * CELL_H - off_y + HEADER_SIZE;

                _ = c.SDL_SetRenderDrawColor(ren, CT_SURFACE0.r, CT_SURFACE0.g, CT_SURFACE0.b, 255);
                _ = c.SDL_RenderRect(ren, &c.SDL_FRect{ .x = x, .y = y, .w = CELL_W, .h = CELL_H });

                if (r != sel_r or col != sel_c) {
                    if (sheet.cells.getPtr(.{ .r = r, .col = col })) |cell| {
                        if (cell.display_len > 0) {
                            const full_txt = cell.evaluated_display[0..cell.display_len];
                            // TTF_MeasureText 대신 직접 만든 안전한 함수 사용
                            const safe_txt = getSafeWidthText(font, full_txt, CELL_W - 12);

                            if (safe_txt.len > 0) {
                                const tex = try lru.fetch(ren, font, safe_txt, CT_TEXT);
                                var tw: f32 = 0;
                                var th: f32 = 0;
                                _ = c.SDL_GetTextureSize(tex, &tw, &th);
                                _ = c.SDL_RenderTexture(ren, tex, null, &c.SDL_FRect{ .x = x + 6, .y = y + (CELL_H - th) / 2, .w = tw, .h = th });
                            }
                        }
                    }
                }
            }
        }

        // 2. 선택된 셀 (오버플로우)
        _ = c.SDL_SetRenderClipRect(ren, &c.SDL_Rect{ .x = @intFromFloat(HEADER_SIZE), .y = @intFromFloat(HEADER_SIZE), .w = @intFromFloat(view_w), .h = @intFromFloat(view_h) });
        {
            const x = @as(f32, @floatFromInt(sel_c)) * CELL_W - off_x + HEADER_SIZE;
            const y = @as(f32, @floatFromInt(sel_r)) * CELL_H - off_y + HEADER_SIZE;

            var buf: [256]u8 = undefined;
            const base = if (sheet.cells.getPtr(.{ .r = sel_r, .col = sel_c })) |cell| cell.raw_input.items else "";
            const txt = std.fmt.bufPrint(&buf, "{s}{s}", .{ base, comp_text[0..comp_len] }) catch "";

            if (txt.len > 0) {
                const tex = try lru.fetch(ren, font, txt, CT_TEXT);
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(tex, &tw, &th);
                _ = c.SDL_SetRenderDrawColor(ren, CT_BASE.r, CT_BASE.g, CT_BASE.b, 255);
                _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = x + 1, .y = y + 1, .w = @max(CELL_W - 2, tw + 10), .h = CELL_H - 2 });
                _ = c.SDL_RenderTexture(ren, tex, null, &c.SDL_FRect{ .x = x + 6, .y = y + (CELL_H - th) / 2, .w = tw, .h = th });
            }
            _ = c.SDL_SetRenderDrawColor(ren, CT_LAVENDER.r, CT_LAVENDER.g, CT_LAVENDER.b, 255);
            _ = c.SDL_RenderRect(ren, &c.SDL_FRect{ .x = x - 1, .y = y - 1, .w = CELL_W + 2, .h = CELL_H + 2 });
        }
        _ = c.SDL_SetRenderClipRect(ren, null);

        // 3. 헤더
        for (s_col..e_col) |col| {
            const x = @as(f32, @floatFromInt(col)) * CELL_W - off_x + HEADER_SIZE;
            if (x < HEADER_SIZE - 1) continue;
            _ = c.SDL_SetRenderDrawColor(ren, CT_MANTLE.r, CT_MANTLE.g, CT_MANTLE.b, 255);
            _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = x, .y = 0, .w = CELL_W, .h = HEADER_SIZE });
            _ = c.SDL_SetRenderDrawColor(ren, CT_SURFACE0.r, CT_SURFACE0.g, CT_SURFACE0.b, 255);
            _ = c.SDL_RenderRect(ren, &c.SDL_FRect{ .x = x, .y = 0, .w = CELL_W, .h = HEADER_SIZE });
            var c_buf: [16]u8 = undefined;
            const tex = try lru.fetch(ren, font, getColName(col, &c_buf), if (col == sel_c) CT_GREEN else CT_SUBTEXT0);
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(tex, &tw, &th);
            _ = c.SDL_RenderTexture(ren, tex, null, &c.SDL_FRect{ .x = x + (CELL_W - tw) / 2, .y = (HEADER_SIZE - th) / 2, .w = tw, .h = th });
        }
        for (s_row..e_row) |r| {
            const y = @as(f32, @floatFromInt(r)) * CELL_H - off_y + HEADER_SIZE;
            if (y < HEADER_SIZE - 1) continue;
            _ = c.SDL_SetRenderDrawColor(ren, CT_MANTLE.r, CT_MANTLE.g, CT_MANTLE.b, 255);
            _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = 0, .y = y, .w = HEADER_SIZE, .h = CELL_H });
            _ = c.SDL_SetRenderDrawColor(ren, CT_SURFACE0.r, CT_SURFACE0.g, CT_SURFACE0.b, 255);
            _ = c.SDL_RenderRect(ren, &c.SDL_FRect{ .x = 0, .y = y, .w = HEADER_SIZE, .h = CELL_H });
            var r_buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&r_buf, "{d}", .{r + 1}) catch "";
            const tex = try lru.fetch(ren, font, s, if (r == sel_r) CT_GREEN else CT_SUBTEXT0);
            var tw: f32 = 0;
            var th: f32 = 0;
            _ = c.SDL_GetTextureSize(tex, &tw, &th);
            _ = c.SDL_RenderTexture(ren, tex, null, &c.SDL_FRect{ .x = (HEADER_SIZE - tw) / 2, .y = y + (CELL_H - th) / 2, .w = tw, .h = th });
        }
        _ = c.SDL_SetRenderDrawColor(ren, CT_MANTLE.r, CT_MANTLE.g, CT_MANTLE.b, 255);
        _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = 0, .y = 0, .w = HEADER_SIZE, .h = HEADER_SIZE });

        // 4. 스크롤바
        _ = c.SDL_SetRenderDrawColor(ren, CT_MANTLE.r, CT_MANTLE.g, CT_MANTLE.b, 255);
        _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = win_w - SB_WIDTH, .y = 0, .w = SB_WIDTH, .h = win_h });
        _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = 0, .y = win_h - SB_WIDTH, .w = win_w, .h = SB_WIDTH });
        const v_h = @max(30, (view_h / full_h) * view_h);
        const v_y = HEADER_SIZE + (off_y / (full_h - view_h)) * (view_h - v_h);
        const h_w = @max(30, (view_w / full_w) * view_w);
        const h_x = HEADER_SIZE + (off_x / (full_w - view_w)) * (view_w - h_w);
        _ = c.SDL_SetRenderDrawColor(ren, CT_SURFACE0.r, CT_SURFACE0.g, CT_SURFACE0.b, 255);
        _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = win_w - SB_WIDTH + 2, .y = v_y, .w = SB_WIDTH - 4, .h = v_h });
        _ = c.SDL_RenderFillRect(ren, &c.SDL_FRect{ .x = h_x, .y = win_h - SB_WIDTH + 2, .w = h_w, .h = SB_WIDTH - 4 });

        _ = c.SDL_RenderPresent(ren);
    }
}
