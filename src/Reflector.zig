const std = @import("std");
const types = @import("types.zig");
const descriptors = @import("descriptors.zig");

const Reflector = @This();

allocator: std.mem.Allocator,
env: *types.JNIEnv,

pub fn init(allocator: std.mem.Allocator, env: *types.JNIEnv) Reflector {
    return .{ .allocator = allocator, .env = env };
}

pub fn getClass(self: *Reflector, name: [*:0]const u8) !Class {
    return Class.init(self, try self.env.newReference(.global, try self.env.findClass(name)));
}

pub fn ObjectType(comptime name_: []const u8) type {
    return struct {
        pub const object_class_name = name_;
    };
}

pub const StringChars = union(enum) {
    utf8: [:0]const u8,
    unicode: []const u16,
};

pub const String = struct {
    const Self = @This();
    const object_class_name = "java/lang/String";

    reflector: *Reflector,
    chars: StringChars,
    string: types.jstring,

    pub fn init(reflector: *Reflector, chars: StringChars) !Self {
        var string = try switch (chars) {
            .utf8 => |buf| reflector.env.newStringUTF(@ptrCast(buf)),
            .unicode => |buf| reflector.env.newString(buf),
        };

        return Self{ .reflector = reflector, .chars = chars, .string = string };
    }

    /// Only use when a string is `get`-ed
    /// Tells the JVM that the string you've obtained is no longer being used
    pub fn release(self: Self) void {
        switch (self.chars) {
            .utf8 => |buf| self.reflector.env.releaseStringUTFChars(self.string, @ptrCast(buf)),
            .unicode => |buf| self.reflector.env.releaseStringChars(self.string, @ptrCast(buf)),
        }
    }

    pub fn toJValue(self: Self) types.jvalue {
        return .{ .l = self.string };
    }

    pub fn fromObject(reflector: *Reflector, object: types.jobject) !Self {
        var chars_len = reflector.env.getStringUTFLength(object);
        var chars_ret = try reflector.env.getStringUTFChars(object);

        return Self{ .reflector = reflector, .chars = .{ .utf8 = @ptrCast(chars_ret.chars[0..@intCast(chars_len)])}, .string = object };
    }

    pub fn fromJValue(reflector: *Reflector, value: types.jvalue) !Self {
        return fromObject(reflector, value.l);
    }
};

fn valueToDescriptor(comptime T: type) descriptors.Descriptor {
    if (@typeInfo(T) == .Struct and @hasDecl(T, "object_class_name")) {
        return .{ .object = @field(T, "object_class_name") };
    }

    return switch (T) {
        types.jint => .int,
        void => .void,
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    };
}

fn funcToMethodDescriptor(comptime func: type) descriptors.MethodDescriptor {
    const Fn = @typeInfo(func).Fn;
    var parameters: [Fn.args.len]descriptors.Descriptor = undefined;

    inline for (Fn.args, 0..) |param, u| {
        parameters[u] = valueToDescriptor(param.arg_type.?);
    }

    return .{
        .parameters = &parameters,
        .return_type = &valueToDescriptor(Fn.return_type.?),
    };
}

fn sm(comptime func: type) type {
    return StaticMethod(funcToMethodDescriptor(func));
}

fn nsm(comptime func: type) type {
    return Method(funcToMethodDescriptor(func));
}

fn cnsm(comptime func: type) type {
    return Constructor(funcToMethodDescriptor(func));
}

pub const Object = struct {
    const Self = @This();

    class: *Class,
    object: types.jobject,

    pub fn init(class: *Class, object: types.jobject) Self {
        return .{ .class = class, .object = object };
    }
};

pub const Class = struct {
    const Self = @This();

    reflector: *Reflector,
    class: types.jclass,

    pub fn init(reflector: *Reflector, class: types.jclass) Self {
        return .{ .reflector = reflector, .class = class };
    }

    /// Creates an instance of the current class without invoking constructors
    pub fn create(self: *Self) !Object {
        return Object.init(self, try self.reflector.env.allocObject(self.class));
    }

    pub fn getConstructor(self: *Self, comptime func: type) !cnsm(func) {
        return try self.getConstructor_(cnsm(func));
    }

    fn getConstructor_(self: *Self, comptime T: type) !T {
        var buf = std.ArrayList(u8).init(self.reflector.allocator);
        defer buf.deinit();

        try @field(T, "descriptor_").toStringArrayList(&buf);
        try buf.append(0);

        return T{ .class = self, .method_id = try self.reflector.env.getMethodId(self.class, "<init>", @ptrCast(buf.items)) };
    }

    pub fn getMethod(self: *Self, name: [*:0]const u8, comptime func: type) !nsm(func) {
        return try self.getMethod_(nsm(func), name);
    }

    fn getMethod_(self: *Self, comptime T: type, name: [*:0]const u8) !T {
        var buf = std.ArrayList(u8).init(self.reflector.allocator);
        defer buf.deinit();

        try @field(T, "descriptor_").toStringArrayList(&buf);
        try buf.append(0);

        return T{ .class = self, .method_id = try self.reflector.env.getMethodId(self.class, name, @ptrCast(buf.items)) };
    }

    pub fn getStaticMethod(self: *Self, name: [*:0]const u8, comptime func: type) !sm(func) {
        return try self.getStaticMethod_(sm(func), name);
    }

    fn getStaticMethod_(self: *Self, comptime T: type, name: [*:0]const u8) !T {
        var buf = std.ArrayList(u8).init(self.reflector.allocator);
        defer buf.deinit();

        try @field(T, "descriptor_").toStringArrayList(&buf);
        try buf.append(0);

        return T{ .class = self, .method_id = try self.reflector.env.getStaticMethodId(self.class, name, @ptrCast(buf.items)) };
    }
};

fn MapDescriptorLowLevelType(comptime value: *const descriptors.Descriptor) type {
    return switch (value.*) {
        .byte => types.jbyte,
        .char => types.jchar,

        .int => types.jint,
        .long => types.jlong,
        .short => types.jshort,

        .float => types.jfloat,
        .double => types.jdouble,

        .boolean => types.jboolean,
        .void => void,

        .object => types.jobject,
        .array => types.jarray,
        .method => unreachable,
    };
}

fn MapDescriptorType(comptime value: *const descriptors.Descriptor) type {
    return switch (value.*) {
        .byte => types.jbyte,
        .char => types.jchar,

        .int => types.jint,
        .long => types.jlong,
        .short => types.jshort,

        .float => types.jfloat,
        .double => types.jdouble,

        .boolean => types.jboolean,
        .void => void,

        .object => |name| if (std.mem.eql(u8, name, "java/lang/String"))
            String
        else
            types.jobject,
        .array => types.jarray,
        .method => unreachable,
    };
}

fn MapDescriptorToNativeTypeEnum(comptime value: *const descriptors.Descriptor) types.NativeType {
    return switch (value.*) {
        .byte => .byte,
        .char => .char,

        .int => .int,
        .long => .long,
        .short => .short,

        .float => .float,
        .double => .double,

        .boolean => .boolean,

        .object, .array => .object,
        .void => .void,
        .method => unreachable,
    };
}

fn ArgsFromDescriptor(comptime descriptor: *const descriptors.MethodDescriptor) type {
    var Ts: [descriptor.parameters.len]type = undefined;
    for (descriptor.parameters, 0..) |param, i| Ts[i] = MapDescriptorType(&param);
    return std.meta.Tuple(&Ts);
}

pub fn Constructor(comptime descriptor: descriptors.MethodDescriptor) type {
    return struct {
        const Self = @This();
        pub const descriptor_ = descriptor;

        class: *Class,
        method_id: types.jmethodID,

        pub fn call(self: Self, args: ArgsFromDescriptor(&descriptor)) !Object {
            var processed_args: [args.len]types.jvalue = undefined;
            comptime var index: usize = 0;
            inline while (index < args.len) : (index += 1) {
                processed_args[index] = types.jvalue.toJValue(args[index]);
            }

            return Object.init(self.class, try self.callJValues(&processed_args));
        }

        pub fn callJValues(self: Self, args: []types.jvalue) types.JNIEnv.NewObjectError!types.jobject {
            return self.class.reflector.env.newObject(self.class.class, self.method_id, if (args.len == 0) null else @ptrCast(args));
        }
    };
}

pub fn Method(descriptor: descriptors.MethodDescriptor) type {
    return struct {
        const Self = @This();
        pub const descriptor_ = descriptor;

        class: *Class,
        method_id: types.jmethodID,

        pub fn call(self: Self, object: Object, args: ArgsFromDescriptor(&descriptor)) !MapDescriptorType(descriptor.return_type) {
            var processed_args: [args.len]types.jvalue = undefined;
            comptime var index: usize = 0;
            inline while (index < args.len) : (index += 1) {
                processed_args[index] = types.jvalue.toJValue(args[index]);
            }

            var ret = try self.callJValues(object.object, &processed_args);
            const mdt = MapDescriptorType(descriptor.return_type);
            return if (@typeInfo(mdt) == .Struct and @hasDecl(mdt, "fromJValue")) @field(mdt, "fromJValue")(self.class.reflector, .{ .l = ret }) else ret;
        }

        pub fn callJValues(self: Self, object: types.jobject, args: []types.jvalue) types.JNIEnv.CallStaticMethodError!MapDescriptorLowLevelType(descriptor.return_type) {
            return self.class.reflector.env.callMethod(comptime MapDescriptorToNativeTypeEnum(descriptor.return_type), object, self.method_id, if (args.len == 0) null else @ptrCast(args));
        }
    };
}

pub fn StaticMethod(descriptor: descriptors.MethodDescriptor) type {
    return struct {
        const Self = @This();
        const descriptor_ = descriptor;

        class: *Class,
        method_id: types.jmethodID,

        pub fn call(self: Self, args: ArgsFromDescriptor(&descriptor)) !MapDescriptorType(descriptor.return_type) {
            var processed_args: [args.len]types.jvalue = undefined;
            comptime var index: usize = 0;
            inline while (index < args.len) : (index += 1) {
                processed_args[index] = types.jvalue.toJValue(args[index]);
            }

            var ret = try self.callJValues(&processed_args);
            const mdt = MapDescriptorType(descriptor.return_type);
            return if (@typeInfo(mdt) == .Struct and @hasDecl(mdt, "fromJValue")) @field(mdt, "fromJValue")(self.class.reflector, .{ .l = ret }) else ret;
        }

        pub fn callJValues(self: Self, args: []types.jvalue) types.JNIEnv.CallStaticMethodError!MapDescriptorLowLevelType(descriptor.return_type) {
            return self.class.reflector.env.callStaticMethod(comptime MapDescriptorToNativeTypeEnum(descriptor.return_type), self.class.class, self.method_id, if (args.len == 0) null else @ptrCast(args));
        }
    };
}
