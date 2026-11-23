# glmt

glmt is OpenGL 1.x on Metal, for one family of games. It implements the calls id Tech 3 makes,
the engine under Quake III Arena and Quake Live, and it runs inside
[Wine](https://gitlab.winehq.org/wine/wine) on an Apple silicon Mac.
Wine's Mac driver loads `libglmt.dylib` and hands the game its entry points in place of Apple's
OpenGL.

I wrote it because nothing existing fit. [ANGLE](https://github.com/google/angle) and
[MetalANGLE](https://github.com/kakashidinho/metalangle) translate OpenGL ES.
[MGL](https://github.com/openglonmetal/MGL) covers modern core OpenGL and has no fixed-function
pipeline. Apple's own OpenGL gives a GL 1.x game its
legacy 2.1 driver, where Quake Live ran at 60 to 70 fps with stutter on my M5 Max. [Mesa](https://gitlab.freedesktop.org/mesa/mesa)'s
[Zink](https://docs.mesa3d.org/drivers/zink.html) would work, but it stacks OpenGL on Vulkan on
Metal, and I wanted one translation, not three.

With glmt the same game holds 250 fps at 3840x2160 on that Mac.

## What it covers

OpenGL 1.3 as a version string, and of that the fixed-function subset id Tech 3 draws with.

- Vertex arrays with `glDrawElements` and `glDrawArrays`, and `glBegin` to `glEnd`.
- Two texture units with the modulate, replace, decal and add environments.
- Alpha test, blending, depth, stencil, scissor, polygon offset, culling, colour mask, one clip
  plane.
- Matrix stacks, `glOrtho`, `glFrustum`, `glReadPixels`.
- The attribute stacks, because Steam's overlay draws into the game's frame with
  `glPushAttrib` and `glPushClientAttrib`.

The extensions it offers are `GL_ARB_multitexture`, `GL_EXT_compiled_vertex_array`,
`GL_EXT_texture_env_add` with its ARB name, `GL_EXT_texture_filter_anisotropic`, the two edge
clamp names and `GL_EXT_bgra`. The compiled vertex array extension matters most. With it id
Tech 3 draws through `glDrawElements`. Without it the engine makes one `glArrayElement` call per
index.

It has no shaders, framebuffer objects, buffer objects, display lists or compressed textures. A
game that asks for those gets a NULL entry point or no extension, and Quake Live then stays on
its fixed-function path with bloom and colour correction off. Flat shading, `GL_CLAMP`'s border,
line width and point size are not honoured. glmt logs the first call of every OpenGL 1.1 function
it doesn't implement, so a new game tells you what it misses.

## How it is put together

A portable C front end keeps OpenGL's state and turns draws into packets. A backend executes the
packets. There are two backends. `metal` draws, and `null` throws the packets away, which
measures what the game and Wine cost before Metal does anything.

| File | What |
|---|---|
| `include/glmt.h` | The interface to the host, Wine's Mac driver. No Wine, OpenGL or Metal types. |
| `src/gl_impl.inc` | The list of OpenGL entry points glmt implements. |
| `src/gl_core.inc` | The OpenGL 1.1 names. One without an implementation gets a stub that logs its first call. |
| `src/state.c`, `matrix.c`, `texture.c`, `draw.c`, `attrib.c` | The front end. |
| `src/backend.h` | The packets and the backend's interface. |
| `src/backend_null.c` | Draws nothing. |
| `src/backend_metal.m`, `src/shaders.metal` | Metal. |
| `tests/` | The front end against a backend that records its packets. |
| `tools/smoke.m` | The Metal backend without Wine. It draws through the OpenGL entry points and reads pixels back. |

A draw packet carries its whole state as small keys for the pipeline, depth, stencil, raster and
sampler state, plus the viewport, the scissor, two textures and offsets into a per-frame arena
that holds uniforms, vertices and indices. Packets hold no pointers. That is why the tests can
record and compare them.

### What id Tech 3 does, and what glmt does with it

I read this in id's GPL source of
[Quake III Arena](https://github.com/id-Software/Quake-III-Arena). Quake Live's renderer is a closed descendant
and may differ.

The engine sets positions once per surface and locks them with `glLockArraysEXT`. Each shader
stage then writes new colours and texture coordinates to the same addresses and calls
`glDrawElements`. glmt copies an array that was enabled at the lock once per lock, and any other
array once per draw. Positions keep the game's 16-byte layout, so a lock is one `memcpy`.

The game binds textures by names it never generated and uploads one mip level per call. glmt
keeps uploads in memory until the first draw, then makes the Metal texture with the levels it
has. Everything is stored as RGBA 8888.

### No shader compiles while the game runs

One vertex function and one fragment function cover the whole subset. Texture environment, alpha
function and alpha reference are uniforms. Discard and the clip distance are function constants,
which makes four specializations, because either would cost every draw if it were always on. A
pipeline is one of those four plus a vertex layout, blend factors and a colour mask. A session
uses a few dozen.

### OpenGL's conventions on Metal

Clip space agrees in x and y, so nothing is mirrored and winding stays the same. The
framebuffer's origin differs, so glmt flips viewport, scissor and read-back rectangles, and the
vertex function maps depth from -w..w to 0..w.

A clear at the start of a frame is the render pass's load action. A clear in the middle of a
frame, which id Tech 3 does for depth before each view, is a triangle over the surface with a
depth state that always passes. Ending the render pass there would make the GPU store and reload
every tile.

### Frames to the display

glmt draws every frame into a texture of its own and copies it into a drawable at the swap.
`GLMT_PRESENT` picks how.

| Value | What happens |
|---|---|
| `tear` | Display sync off. The game's thread takes a drawable and presents every frame at once. This is glmt's default. |
| `async` | The same picture, but a thread of glmt's takes the drawable, so the game's thread never waits for one. QL on Mac's scripts use this. |
| `mailbox` | Display sync on, one frame per refresh. No tearing, and each frame is a refresh late. |
| `wait` | Every frame, waiting for a drawable. |

On my 60 Hz display an unsynced frame is on screen about 3 ms after the swap, and a synced one
17 ms or more. I spent a night trying to time unsynced flips into the blanking interval and
found no schedule macOS would keep.

## Building and testing

```sh
make test          # the front end's tests, on any system with gcc or clang
make               # macOS: libglmt.dylib, arm64, with the Metal backend
make shadercheck   # macOS: the shaders through Metal's compiler, each specialization as a pipeline
make smoke         # macOS: 50 pixel checks of the Metal backend, without Wine
```

`make test` runs 385 checks against the recording backend. They also pass under the undefined
behaviour sanitizer, and under the address sanitizer with leak detection off, because the test's
recording backend never frees what it records.

`make smoke` is where "which way is up" gets checked and not argued. It draws through the OpenGL
entry points and reads the pixels back with `glReadPixels`. A change to the Metal backend gets a
scene there.

## Using it in Wine

glmt has no window system code. The host gives it a `CAMetalLayer` and asks for entry points by
name. In [QL on Mac](../README.md) the host is Wine's Mac driver with
[`patches/wine/0001-winemac-glmt.patch`](../patches/wine/0001-winemac-glmt.patch), which loads
the library for `quakelive_steam.exe`, or for the programs `WINE_GLMT_EXE` names.

Environment variables, read once at start.

| Variable | What it does |
|---|---|
| `GLMT_BACKEND` | `metal`, the default, or `null`. |
| `GLMT_PRESENT` | See above. |
| `GLMT_LOG` | The log file. |
| `GLMT_STATS` | `N` writes a line every N frames with fps, OpenGL calls, draws and vertices a frame, and frame times. |
| `GLMT_DEBUG` | `1` logs OpenGL errors with the entry point, plus contexts, surfaces and textures. |
| `GLMT_TRACE` | `"30 400"` logs every entry point by name in those frames. |
| `GLMT_FLIP_TRACE` | A file that gets every swap and every flip as a line. `tools/flipread.py` reads it. |

## Another game

glmt was written against one game. Another id Tech 3 game is the likely next one, and it should
come close. Start it with `GLMT_DEBUG=1` and read the log. It names every call glmt lacks.

A new entry point goes into `src/gl_impl.inc` with a test in `tests/`. Be careful with
extensions. Each one you add can move a game onto a code path glmt doesn't have.

## Licence

LGPL 2.1 or later. See [`LICENSE`](../LICENSE).
