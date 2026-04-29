const rl = @import("raylib");
const std = @import("std");

pub fn drawCentered(font: rl.Font, text: [:0]const u8, rect: rl.Rectangle, fSize: f32, color: rl.Color) void {
    const tSize = rl.measureTextEx(font, text, fSize, 1);
    rl.drawTextEx(font, text, rl.Vector2{ .x = rect.x + (rect.width - tSize.x) / 2, .y = rect.y + (rect.height - tSize.y) / 2 }, fSize, 1, color);
}
