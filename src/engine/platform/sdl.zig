pub const c = @cImport({
    @cDefine("SDL_MAIN_HANDLED", "1");
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_gpu.h");
});
