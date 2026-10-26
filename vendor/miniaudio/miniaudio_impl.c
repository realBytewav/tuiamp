/* The single translation unit that instantiates miniaudio.
 *
 * Configuration macros live in build.zig via addCMacro so that this file and
 * the @cImport in src/c.zig are compiled with identical struct layouts. Do not
 * #define miniaudio options here. */
#define MA_IMPLEMENTATION
#include "miniaudio.h"
