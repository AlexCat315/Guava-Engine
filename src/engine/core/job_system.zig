const std = @import("std");

pub const JobPriority = enum {
    high,
    normal,
    low,
};

pub const JobStatus = enum(u8) {
    pending,
    running,
    completed,
    failed,
};

pub const JobHandle = struct {
    id: u64,
    status: *std.atomic.Value(JobStatus),

    pub fn isDone(self: JobHandle) bool {
        return self.status.load(.acquire) == .completed;
    }

    pub fn wait(self: JobHandle) void {
        while (!self.isDone()) {
            std.Thread.yield() catch {};
        }
    }
};

pub const JobFunc = *const fn (context: ?*anyopaque) void;

const Job = struct {
    id: u64,
    func: JobFunc,
    context: ?*anyopaque,
    priority: JobPriority,
    status: *std.atomic.Value(JobStatus),
};

pub const JobSystem = struct {
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    queue: std.ArrayList(Job),
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    running: std.atomic.Value(bool),
    job_id_counter: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, thread_count: ?usize) !*JobSystem {
        const actual_thread_count = thread_count orelse (std.Thread.getCpuCount() catch 4);
        const self = try allocator.create(JobSystem);
        self.* = .{
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, actual_thread_count),
            .queue = std.ArrayList(Job).empty,
            .mutex = .{},
            .condition = .{},
            .running = std.atomic.Value(bool).init(true),
            .job_id_counter = std.atomic.Value(u64).init(0),
        };

        for (0..actual_thread_count) |i| {
            self.threads[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        return self;
    }

    pub fn deinit(self: *JobSystem) void {
        self.running.store(false, .release);
        self.condition.broadcast();
        
        for (self.threads) |thread| {
            thread.join();
        }
        
        self.queue.deinit(self.allocator);
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    pub fn enqueue(self: *JobSystem, func: JobFunc, context: ?*anyopaque, priority: JobPriority) !JobHandle {
        const id = self.job_id_counter.fetchAdd(1, .monotonic);
        const status = try self.allocator.create(std.atomic.Value(JobStatus));
        status.store(.pending, .release);

        const job = Job{
            .id = id,
            .func = func,
            .context = context,
            .priority = priority,
            .status = status,
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.queue.append(self.allocator, job);
        }
        
        self.condition.signal();
        return JobHandle{ .id = id, .status = status };
    }

    fn workerLoop(self: *JobSystem) void {
        while (self.running.load(.acquire)) {
            var job: ?Job = null;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                
                while (self.queue.items.len == 0 and self.running.load(.acquire)) {
                    self.condition.wait(&self.mutex);
                }
                
                if (self.queue.items.len > 0) {
                    // Simple FIFO for now, ignoring priority for implementation speed
                    job = self.queue.orderedRemove(0);
                }
            }

            if (job) |j| {
                j.status.store(.running, .release);
                j.func(j.context);
                j.status.store(.completed, .release);
            }
        }
    }
};
