#!/bin/zsh
# Build the two unix libraries patches/wine changes, the Mac driver (dlls/winemac.drv/winemac.so)
# and dlls/win32u/win32u.so, the way Mach9 0.4.0's CI built the engine's own. Runs on the Mac (scripts/build-winemac.zsh) and on a macOS
# runner (.github/workflows/build.yml).
#
#   ci/wine.zsh prepare <commit> <patches>   check $SRC out at <commit>, give it the wine-11.21
#                                            tag and apply every patch in <patches>
#   ci/wine.zsh configure                    configure a tree in $BUILD for $SRC
#   ci/wine.zsh build                        build winemac.so and win32u.so in $BUILD
#   ci/wine.zsh opengl32                     build opengl32.so and the 32-bit opengl32.dll in $BUILD
#                                            (patches/wine/0004: OpenGL calls in batches)
#
# This is .github/gw2/wine.zsh of my Wine fork (jdrly/wine, branch gw2-on-mac), cut down to the one
# file: read that script for why each configure argument is what it is. In short: Mach9's arguments
# with GStreamer off, and the three library names Mach9's config.h ends up with given to configure
# as cached answers, so nothing links against the libraries themselves.
#
# WINE_SHALLOW=1: $SRC holds the one commit only (a shallow fetch), so prepare fetches no release
#   tag; Wine's version string then lacks the commit, which only ntdll.so carries.
# WINE_WITHOUT="sdl gnutls": configure without these. Neither changes anything in winemac.so, and
#   a Mac without Homebrew's sdl2-compat or gnutls can build it this way.
emulate -L zsh
setopt err_exit pipe_fail no_unset extended_glob

: ${SRC:?a clone of jdrly/wine with its history} ${BUILD:?the build folder}
: ${MINGW_DIR:?the llvm-mingw directory}
brew=/opt/homebrew
bundled=@loader_path/../../external
# appended: llvm-mingw's unprefixed clang mustn't replace Apple's
path+=("$MINGW_DIR/bin")

prepare() {
  local commit=$1 patches=$2 version patch
  git -C "$SRC" checkout --quiet --force --detach "$commit"
  # (an earlier run's patch is in the index and the tree: back to the commit itself)
  git -C "$SRC" reset --quiet --hard "$commit"
  if [[ -z ${WINE_SHALLOW:-} ]]; then
    version=$(sed -n 's/^Wine version //p' "$SRC/VERSION")
    git -C "$SRC" fetch --quiet --no-tags https://github.com/wine-mirror/wine \
      "refs/tags/wine-${version}:refs/tags/wine-${version}"
    git -C "$SRC" config core.abbrev 10
  fi
  for patch in $patches/*.patch(N); do
    git -C "$SRC" apply --index "$patch"
    print "applied ${patch:t}"
  done
  # (the new source file is in dlls/winemac.drv/Makefile.in's SOURCES, which is all makedep reads)
  [[ -n ${WINE_SHALLOW:-} ]] || git -C "$SRC" describe HEAD
}

configure() {
  local args=(
    --enable-archs=arm64ec,aarch64,i386
    --with-coreaudio --with-freetype --with-gnutls --without-gstreamer --with-mingw --with-opencl
    --with-opengl --with-sdl --with-vulkan
    --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg --without-fontconfig
    --without-gettext --without-gphoto --without-gssapi --without-hwloc --without-inotify --without-krb5
    --without-netapi --without-oss --without-pcap --without-pcsclite --without-pulse --without-sane
    --without-udev --without-usb --without-v4l2 --without-va --without-wayland --without-x
    --without-xcomposite --without-xcursor --without-xfixes --without-xinerama --without-xinput
    --without-xinput2 --without-xrandr --without-xrender --without-xshape --without-xshm
    --without-xxf86vm
    CC="clang -arch arm64" --host=aarch64-apple-darwin --disable-tests
    BISON="$brew/opt/bison/bin/bison" PKG_CONFIG_PATH="$brew/lib/pkgconfig"
    CPPFLAGS="-I$brew/include" LDFLAGS="-L$brew/lib"
    ac_cv_func_pipe2=no
    ac_cv_lib_soname_EGL=$bundled/libEGL.1.dylib
    ac_cv_lib_soname_freetype=$bundled/libfreetype.6.dylib
    ac_cv_lib_soname_vulkan=$bundled/libvulkan.1.dylib
  )
  local without i
  for without in ${=WINE_WITHOUT:-}; do
    i=${args[(I)--with-$without]}
    (( i )) && args[i]=--without-$without
  done
  mkdir -p "$BUILD"
  cd "$BUILD"
  "$SRC/configure" -C "${args[@]}"
}

build() {
  local file=$BUILD/dlls/winemac.drv/winemac.so win32u=$BUILD/dlls/win32u/win32u.so
  make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so dlls/win32u/win32u.so
  [[ "$(lipo -archs "$file")" == arm64 && "$(lipo -archs "$win32u")" == arm64 ]] || { print -u2 "$file or $win32u is not arm64"; exit 1 }
  grep -q -a 'libglmt.dylib' "$file" || { print -u2 "$file has no glmt glue: the patch did not build in"; exit 1 }
  print "built $file and $win32u"
}

# The pair that batches OpenGL calls: the unix library and the DLL of the 32-bit side, which have
# to match each other (the DLL calls a unix function the engine's own opengl32.so does not have).
opengl32() {
  local so=$BUILD/dlls/opengl32/opengl32.so dll=$BUILD/dlls/opengl32/i386-windows/opengl32.dll
  make -C "$BUILD" -j"$(sysctl -n hw.ncpu)" dlls/opengl32/opengl32.so dlls/opengl32/i386-windows/opengl32.dll
  [[ "$(lipo -archs "$so")" == arm64 ]] || { print -u2 "$so is not arm64"; exit 1 }
  [[ "$(file -b "$dll")" == PE32\ executable*Intel\ 80386* ]] || { print -u2 "$dll is not a 32-bit PE file: $(file -b "$dll")"; exit 1 }
  grep -q -a 'WINE_GLMT_BATCH' "$so" || { print -u2 "$so has no batching: the patch did not build in"; exit 1 }
  print "built $so and $dll"
}

case ${1:-}:$# in
  prepare:3 | configure:1 | build:1 | opengl32:1) "$@" ;;
  *) print -u2 "usage: wine.zsh prepare <commit> <patches> | configure | build | opengl32"; exit 2 ;;
esac
