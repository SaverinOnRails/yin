pub const Message = union(enum) { StaticImage: StaticImage };

pub const StaticImage = struct { path: []u8 };
