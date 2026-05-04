const std = @import("std");
const zla = @import("zla");

pub const Pose = struct {
    position: @Vector(3, f64) = @splat(0),
    rotation: zla.Quaternion(f64) = .{ .w = 1, .x = 0, .y = 0, .z = 0 },

    pub fn identity() Pose {
        return .{};
    }
};

pub const Geometry = union(enum) { cube: CubeGeometry, sphere: SphereGeometry, cylinder: CylinderGeometry, arrow: ArrowGeometry, frame: FrameGeometry, mesh: MeshGeometry };

pub const CubeGeometry = struct {
    width: f32 = 1,
    height: f32 = 1,
    depth: f32 = 1,
};

pub const SphereGeometry = struct {
    radius: f32 = 0.5,
    width_segments: u16 = 32,
    height_segments: u16 = 16,
};

pub const CylinderGeometry = struct {
    radius_top: f32 = 0.5,
    radius_bottom: f32 = 0.5,
    height: f32 = 1,
    radial_segments: u16 = 32,
};

pub const ArrowGeometry = struct {
    length: f32 = 1,
    shaft_radius: f32 = 0.02,
    head_length: f32 = 0.2,
    head_radius: f32 = 0.06,
};

pub const FrameGeometry = struct {
    axis_length: f32 = 1,
    axis_radius: f32 = 0.01,
};

pub const MeshGeometry = struct {
    path: []const u8,
};

pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
};

pub const Material = struct {
    color: Color = .{},
    opacity: f32 = 1.0,
    metalness: f32 = 0.0,
    roughness: f32 = 0.5,
};

pub const Object = struct {
    geometry: Geometry,
    material: Material = .{},
    pose: Pose = .{},
};

test "pose identity matches default pose" {
    try std.testing.expectEqualDeep(Pose{}, Pose.identity());
}

test "geometry default values" {
    const cube = Geometry{ .cube = .{} };
    try std.testing.expectEqual(@as(f32, 1), cube.cube.width);
    try std.testing.expectEqual(@as(f32, 1), cube.cube.height);
    try std.testing.expectEqual(@as(f32, 1), cube.cube.depth);

    const sphere = Geometry{ .sphere = .{} };
    try std.testing.expectEqual(@as(f32, 0.5), sphere.sphere.radius);
    try std.testing.expectEqual(@as(u16, 32), sphere.sphere.width_segments);
    try std.testing.expectEqual(@as(u16, 16), sphere.sphere.height_segments);

    const cylinder = Geometry{ .cylinder = .{} };
    try std.testing.expectEqual(@as(f32, 0.5), cylinder.cylinder.radius_top);
    try std.testing.expectEqual(@as(f32, 0.5), cylinder.cylinder.radius_bottom);
    try std.testing.expectEqual(@as(f32, 1), cylinder.cylinder.height);
    try std.testing.expectEqual(@as(u16, 32), cylinder.cylinder.radial_segments);

    const arrow = Geometry{ .arrow = .{} };
    try std.testing.expectEqual(@as(f32, 1), arrow.arrow.length);
    try std.testing.expectEqual(@as(f32, 0.02), arrow.arrow.shaft_radius);
    try std.testing.expectEqual(@as(f32, 0.2), arrow.arrow.head_length);
    try std.testing.expectEqual(@as(f32, 0.06), arrow.arrow.head_radius);

    const frame = Geometry{ .frame = .{} };
    try std.testing.expectEqual(@as(f32, 1), frame.frame.axis_length);
    try std.testing.expectEqual(@as(f32, 0.01), frame.frame.axis_radius);
}

test "material default values" {
    const material = Material{};
    try std.testing.expectEqual(@as(u8, 255), material.color.r);
    try std.testing.expectEqual(@as(u8, 255), material.color.g);
    try std.testing.expectEqual(@as(u8, 255), material.color.b);
    try std.testing.expectEqual(@as(f32, 1.0), material.opacity);
    try std.testing.expectEqual(@as(f32, 0.0), material.metalness);
    try std.testing.expectEqual(@as(f32, 0.5), material.roughness);
}

test "object uses default material and pose" {
    const object = Object{ .geometry = .{ .cube = .{ .width = 2 } } };

    try std.testing.expectEqual(@as(f32, 2), object.geometry.cube.width);
    try std.testing.expectEqualDeep(Material{}, object.material);
    try std.testing.expectEqualDeep(Pose{}, object.pose);
}
