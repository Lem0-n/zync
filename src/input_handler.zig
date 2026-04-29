const rl = @import("raylib");
const std = @import("std");
const sheet = @import("spreadsheet.zig");

pub const Mode = enum { Normal, Insert };
pub const Lang = enum { EN, KO };

// 세련된 색상 정의 (Nord Theme 스타일)
pub const ColorBank = struct {
    pub const bg = rl.Color.init(46, 52, 64, 255); // 어두운 배경
    pub const grid = rl.Color.init(59, 66, 82, 255); // 그리드 선
    pub const cell_normal = rl.Color.init(67, 76, 94, 255);
    pub const text = rl.Color.init(236, 239, 244, 255);
    pub const accent_blue = rl.Color.init(129, 161, 193, 255); // Normal 선택
    pub const accent_orange = rl.Color.init(208, 135, 112, 255); // Insert 선택
    pub const header = rl.Color.init(76, 86, 106, 255);
};

pub const InputState = struct {
    mode: Mode = .Normal,
    lang: Lang = .EN,
    moveTimer: f32 = 0,
    backspaceTimer: f32 = 0,
    initialDelay: f32 = 0.25,
    repeatDelay: f32 = 0.04,

    cho: i32 = -1,
    jung: i32 = -1,
    jong: i32 = -1,

    pub fn update(self: *InputState, dt: f32, selR: *i32, selC: *i32, grid: *[sheet.ROWS][sheet.COLS]sheet.Cell) void {
        // [수정] 모드 상관없이 한/영 전환 가능하게 밖으로 뺌
        if (rl.isKeyPressed(.right_alt)) {
            self.lang = if (self.lang == .EN) .KO else .EN;
            self.resetHangul();
        }

        if (self.mode == .Normal) {
            if (rl.isKeyPressed(.i)) {
                self.mode = .Insert;
                self.resetHangul();
                _ = rl.getCharPressed();
            }
        } else {
            if (rl.isKeyPressed(.escape)) {
                self.mode = .Normal;
                self.resetHangul();
            }
        }

        if (self.mode == .Normal) {
            self.handleMovement(dt, selR, selC);
        } else {
            self.handleTyping(dt, selR.*, selC.*, grid);
        }
    }

    fn resetHangul(self: *InputState) void {
        self.cho = -1;
        self.jung = -1;
        self.jong = -1;
    }

    fn handleTyping(self: *InputState, dt: f32, r: i32, c: i32, grid: *[sheet.ROWS][sheet.COLS]sheet.Cell) void {
        var cell = &grid[@as(usize, @intCast(r))][@as(usize, @intCast(c))];

        if (rl.isKeyDown(.backspace)) {
            self.backspaceTimer += dt;
            if (rl.isKeyPressed(.backspace)) {
                self.resetHangul();
                cell.deleteLastChar();
            }
            if (self.backspaceTimer > self.initialDelay) {
                if (self.backspaceTimer > self.initialDelay + 0.05) {
                    self.resetHangul();
                    cell.deleteLastChar();
                    self.backspaceTimer = self.initialDelay;
                }
            }
        } else self.backspaceTimer = 0;

        var key = rl.getCharPressed();
        while (key > 0) {
            if (self.lang == .KO) self.processHangul(cell, @intCast(key)) else self.appendRaw(cell, @intCast(key));
            key = rl.getCharPressed();
        }
    }

    fn processHangul(self: *InputState, cell: *sheet.Cell, key: u8) void {
        const en = "qwertyuiopasdfghjklzxcvbnm";
        const cho_map = [_]i32{ 9, 12, 3, 1, 7, 13, 11, 10, 15, 16, 6, 2, 11, 5, 18, 14, 0, 8, 4, 17, 12, 11, 11, 11, 11, 11 };
        const jung_map = [_]i32{ -1, -1, -1, -1, -1, 12, 6, 8, 1, 3, -1, -1, -1, -1, -1, 13, 4, 0, 20, -1, -1, -1, -1, 18, 17, 19 };
        // 종성 매핑 (ㄱ, ㄴ, ㄹ 등 받침용 인덱스)
        const jong_map = [_]i32{ 17, 22, 7, 1, 19, 23, 21, 20, 25, 26, 16, 4, 21, 8, 27, 12, 1, 1, 1, 24, 20, 22, 17, 1, 1, 1 };
        const is_jaum = [_]bool{ true, true, true, true, true, false, false, false, false, false, true, true, true, true, true, false, false, false, false, true, true, true, true, false, false, false };

        var idx: ?usize = null;
        for (en, 0..) |e, i| {
            if (e == key) {
                idx = i;
                break;
            }
        }

        if (idx) |i| {
            if (is_jaum[i]) {
                if (self.cho != -1 and self.jung != -1 and self.jong == -1) {
                    // 받침 입력!
                    self.jong = jong_map[i];
                    cell.deleteLastChar();
                    const combined = 0xAC00 + (@as(u21, @intCast(self.cho)) * 588) + (@as(u21, @intCast(self.jung)) * 28) + @as(u21, @intCast(self.jong));
                    self.appendRaw(cell, combined);
                } else {
                    self.resetHangul();
                    self.cho = cho_map[i];
                    self.appendRaw(cell, 0x3131 + @as(u21, @intCast(self.mapChoToCompat(self.cho))));
                }
            } else { // 모음
                if (self.cho != -1 and self.jung == -1) {
                    self.jung = jung_map[i];
                    cell.deleteLastChar();
                    const combined = 0xAC00 + (@as(u21, @intCast(self.cho)) * 588) + (@as(u21, @intCast(self.jung)) * 28);
                    self.appendRaw(cell, combined);
                } else {
                    self.resetHangul();
                    self.appendRaw(cell, 0x314F + @as(u21, @intCast(jung_map[i])));
                }
            }
        } else {
            self.resetHangul();
            self.appendRaw(cell, key);
        }
    }

    // (기존 mapChoToCompat, appendRaw, handleMovement 로직 동일)
    fn mapChoToCompat(self: *InputState, cho: i32) i32 {
        _ = self;
        const map = [_]i32{ 0, 1, 3, 6, 7, 8, 16, 17, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29 };
        if (cho >= 0 and cho < 19) return map[@intCast(cho)];
        return 0;
    }

    fn appendRaw(self: *InputState, cell: *sheet.Cell, codepoint: u21) void {
        _ = self;
        var buf: [4]u8 = undefined;
        if (std.unicode.utf8Encode(codepoint, &buf)) |len| {
            if (cell.len + len < 127) {
                @memcpy(cell.content[cell.len..][0..len], buf[0..len]);
                cell.len += len;
                cell.content[cell.len] = 0;
            }
        } else |_| {}
    }

    fn handleMovement(self: *InputState, dt: f32, selR: *i32, selC: *i32) void {
        const h = rl.isKeyDown(.h);
        const j = rl.isKeyDown(.j);
        const k = rl.isKeyDown(.k);
        const l = rl.isKeyDown(.l);
        if (h or j or k or l) {
            self.moveTimer += dt;
            if (rl.isKeyPressed(.h)) selC.* = @max(1, selC.* - 1);
            if (rl.isKeyPressed(.l)) selC.* = @min(sheet.COLS - 1, selC.* + 1);
            if (rl.isKeyPressed(.j)) selR.* = @min(sheet.ROWS - 1, selR.* + 1);
            if (rl.isKeyPressed(.k)) selR.* = @max(1, selR.* - 1);
            if (self.moveTimer > self.initialDelay) {
                if (self.moveTimer > self.initialDelay + self.repeatDelay) {
                    if (h) selC.* = @max(1, selC.* - 1);
                    if (l) selC.* = @min(sheet.COLS - 1, selC.* + 1);
                    if (j) selR.* = @min(sheet.ROWS - 1, selR.* + 1);
                    if (k) selR.* = @max(1, selR.* - 1);
                    self.moveTimer = self.initialDelay;
                }
            }
        } else self.moveTimer = 0;
    }
};
