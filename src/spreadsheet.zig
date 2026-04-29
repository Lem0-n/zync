const std = @import("std");

pub const ROWS = 18;
pub const COLS = 8;
pub const CELL_W = 120.0;
pub const CELL_H = 35.0;

pub const Cell = struct {
    content: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,

    pub fn deleteLastChar(self: *Cell) void {
        if (self.len > 0) {
            while (self.len > 0) {
                self.len -= 1;
                // UTF-8 가변 길이 문자 대응 삭제 로직
                if ((self.content[self.len] & 0xC0) != 0x80) break;
            }
            self.content[self.len] = 0;
        }
    }
};
