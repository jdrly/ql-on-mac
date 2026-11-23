# glmt: OpenGL 1.x (the id Tech 3 subset) on Metal.
#
#   make            libglmt.dylib on macOS (arm64, Metal backend); the front end only elsewhere
#   make test       the front end's tests, on any system (they use a recording backend)
#   make shadercheck  macOS: the shaders through Metal's compiler, each specialization as a pipeline
#   make smoke      macOS: libglmt.dylib for a few frames on a layer without a window, without Wine
#   make pace       macOS: where the display tears with each way of presenting (covers the screen)
#   make clean
#
# The front end is portable C and builds with gcc or clang. The Metal backend (backend_metal.m,
# shaders.metal) builds on macOS only.

BUILD ?= build
CC ?= cc
UNAME := $(shell uname -s)

WARN := -Wall -Wextra -Werror -Wmissing-prototypes -Wstrict-prototypes -Wshadow -Wno-unused-parameter
# CFLAGS and LDFLAGS from the command line are added to these (make test CFLAGS=-fsanitize=address).
OPT ?= -O2 -g
FLAGS = $(OPT) -std=c11 -fvisibility=hidden -fPIC -Iinclude -Isrc $(WARN) $(PLATFORM_CFLAGS) $(CFLAGS)

SRC := src/context.c src/state.c src/matrix.c src/texture.c src/draw.c src/attrib.c src/backend_null.c
OBJ := $(SRC:src/%.c=$(BUILD)/%.o)
TESTS := tests/test_main.c tests/record.c

ifeq ($(UNAME),Darwin)
# the engine itself needs macOS 26.4
MIN_MACOS ?= 26.0
ARCH ?= arm64
PLATFORM_CFLAGS := -arch $(ARCH) -mmacosx-version-min=$(MIN_MACOS)
OBJ += $(BUILD)/backend_metal.o
LIB := $(BUILD)/libglmt.dylib
LINK := -arch $(ARCH) -mmacosx-version-min=$(MIN_MACOS) -dynamiclib -install_name @rpath/libglmt.dylib \
	-framework Metal -framework QuartzCore -framework Foundation -framework CoreGraphics -framework CoreVideo
else
# clock_gettime with -std=c11; on macOS the define would hide what Foundation's headers need
PLATFORM_CFLAGS := -D_POSIX_C_SOURCE=200809L
LIB := $(BUILD)/libglmt.so
LINK := -shared
endif

all: $(LIB)

$(BUILD)/%.o: src/%.c $(wildcard src/*.h src/*.inc include/*.h)
	@mkdir -p $(BUILD)
	$(CC) $(FLAGS) -c $< -o $@

# The shader source goes into the library as a string, and Metal compiles it once at start: there is
# one vertex and one fragment function, and Metal keeps the compiled result on disk.
$(BUILD)/shaders.inc: src/shaders.metal tools/embed.py
	@mkdir -p $(BUILD)
	python3 tools/embed.py glmt_shader_source $< > $@

$(BUILD)/backend_metal.o: src/backend_metal.m $(BUILD)/shaders.inc $(wildcard src/*.h include/*.h)
	$(CC) $(FLAGS) -I$(BUILD) -fobjc-arc -c $< -o $@

$(LIB): $(OBJ)
	$(CC) $(OBJ) $(LINK) $(LDFLAGS) -lm -o $@

$(BUILD)/test: $(TESTS) $(SRC) $(wildcard src/*.h src/*.inc include/*.h tests/*.h)
	@mkdir -p $(BUILD)
	$(CC) $(filter-out -fvisibility=hidden,$(FLAGS)) -DGLMT_TEST -Itests $(TESTS) $(SRC) $(LDFLAGS) -lm -o $@

test: $(BUILD)/test
	$(BUILD)/test

# macOS only: the shaders through Metal's compiler, as pipelines (tools/shadercheck.m)
$(BUILD)/shadercheck: tools/shadercheck.m $(BUILD)/shaders.inc src/backend.h
	$(CC) $(FLAGS) -I$(BUILD) -fobjc-arc $< -framework Metal -framework Foundation -framework CoreGraphics -o $@

shadercheck: $(BUILD)/shadercheck
	$(BUILD)/shadercheck

# macOS only: the library itself for a few frames, without Wine (tools/smoke.m)
$(BUILD)/smoke: tools/smoke.m $(LIB) include/glmt.h src/gl.h
	$(CC) $(FLAGS) -fobjc-arc $< -L$(BUILD) -lglmt -Wl,-rpath,@loader_path -framework QuartzCore -framework Foundation -o $@

smoke: $(BUILD)/smoke
	GLMT_DEBUG=1 $(BUILD)/smoke
	GLMT_DEBUG=1 GLMT_PRESENT=async $(BUILD)/smoke

# macOS only: a picture that shows where the display tears, in a window over the whole screen, at
# the game's rate (tools/pace.m): vsync, then tear at 250 and at 125. It covers the screen for 15
# seconds; Escape ends a part.
$(BUILD)/pace: tools/pace.m $(LIB) include/glmt.h src/gl.h
	$(CC) $(FLAGS) -fobjc-arc $< -L$(BUILD) -lglmt -Wl,-rpath,@loader_path -framework Cocoa -framework QuartzCore -o $@

pace: export MTL_HUD_ENABLED = 1
pace: $(BUILD)/pace
	PACE_SYNC=1 $(BUILD)/pace 250 4
	GLMT_PRESENT=tear $(BUILD)/pace 250 6
	GLMT_PRESENT=tear $(BUILD)/pace 125 5

clean:
	rm -rf $(BUILD)

.PHONY: all test shadercheck smoke pace clean
