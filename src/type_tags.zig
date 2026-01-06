pub const @"null": u8 = 0;
pub const boolean: u8 = 1;
pub const int = struct {
    pub const unsigned = struct {
        pub const @"8" = 2;
        pub const @"16" = 3;
        pub const @"32" = 4;
        pub const @"64" = 5;
    };
    pub const signed = struct {
        pub const @"8" = 6;
        pub const @"16" = 7;
        pub const @"32" = 8;
        pub const @"64" = 9;
    };
};
pub const float = struct {
    pub const @"32" = 10;
    pub const @"64" = 11;
};
pub const array: u8 = 12;
pub const struct_start: u8 = 13;
pub const struct_end: u8 = 14;
pub const optional_null: u8 = 15;
pub const optional_value: u8 = 16;


pub fn get(T: type) ?u8 {
    const type_info = @typeInfo(T);
    return switch (type_info) {
        .void, .null => @"null",
        .bool => boolean,
        .int => |int_info| switch (int_info.bits) {
            1...8 => if (int_info.signedness == .signed) int.signed.@"8" else int.unsigned.@"8",
            9...16 => if (int_info.signedness == .signed) int.signed.@"16" else int.unsigned.@"16",
            17...32 => if (int_info.signedness == .signed) int.signed.@"32" else int.unsigned.@"32",
            33...64 => if (int_info.signedness == .signed) int.signed.@"64" else int.unsigned.@"64",
            else => null,
        },
        .float => |float_info| switch (float_info.bits) {
            32 => float.@"32",
            64 => float.@"64",
            else => unreachable,
        },
        .pointer => |ptr_info| if (ptr_info.size == .slice) array else null,
        .array => array,
        .@"struct" => struct_start,
        .optional => optional_null,
        else => null,
    };
}
