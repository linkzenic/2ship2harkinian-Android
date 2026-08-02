#include <SDL.h>

// libultraship's desktop SDL backend references these macOS fullscreen helpers.
// Mobile Apple platforms are always presented fullscreen by the operating system.
extern "C" void toggleNativeMacOSFullscreen(SDL_Window*) {
}

extern "C" bool isNativeMacOSFullscreenActive(SDL_Window*) {
    return false;
}
